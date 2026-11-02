/**
 * Tang Mega 138K Pro ADCLRC 单次转换适配器，支持专用ADCV/ADCT输入选通。
 * 依据本机 Gowin V1.9.12.04 UG299-1.0.6E 和 gw5a/prim_sim.v。
 */
/**
 * in_valid/in_ready: clk_sys 上升沿接受一次采样请求，不接收模拟电压数字引脚。
 * out_valid/out_ready: 交付保持稳定的14位无符号电压码，电压(V)=sample_code/2048。
 * adc_channel请求前选好并保持：0=J3 ADCV，1=J4 ADCT；两组均为专用模拟脚。
 * ADCV 专用模拟输入接 J3.1/N12；负端 J3.3/P11 按板卡/ADC手册接模拟地。
 * 输入必须经模拟前端限制到0..1V；不为专用模拟引脚设置 LVCMOS33。
 * sample_error: 超时单拍通知；adc_error: 超时锁存标志，rst_n清除。
 * 超时后取消旧转换，复位硬核，再等待启动稳定，不把迟到结果作为新样本。
 * ADC_CLK_DIV: 偶数分频比；默认64得到1.536MHz；仅ADC硬核使用该专用时钟。
 * 专用时钟由独立相位计数器译码后寄存，时钟输出不反馈到任何数据逻辑。
 * 译码使用当前相位再寄存，首个上升沿在ADC_CLK_DIV/2+1个系统周期后到达。
 * 该单拍相位延迟避免时钟寄存器与计数器MSB合并，不影响稳定周期和启动等待。
 * 业务逻辑均在clk_sys域；集成时需为clk_adc_r/Q建立ADC_CLK_DIV倍分频约束。
 * ADC_STARTUP_TICKS/ADC_TIMEOUT_TICKS: 系统周期数。
 * SAMPLE_COUNT_SEL/RATE_CHANGE_SEL: 厂商编码；默认128点、16周期，128>7*16。
 * 快配置的有效精度与噪声须实测；不能把调制时钟当成整帧刷新率。
 * NOTE: 一个器件只允许一个ADCLRC实例，不能与独占该硬核的弯音驱动重复实例化。
 */
module keyboard_adc
#(
    parameter integer SYS_CLK_HZ = 98_304_000,
    parameter integer ADC_CLK_DIV = 64,
    parameter integer ADC_STARTUP_TICKS = 98_304,
    parameter integer ADC_TIMEOUT_TICKS = 4096 * ADC_CLK_DIV,
    parameter integer SAMPLE_COUNT_SEL = 1,
    parameter integer RATE_CHANGE_SEL = 2,
    parameter [9:0] FSCAL_VALUE = 10'd653,
    parameter [11:0] OFFSET_VALUE = 12'd0
)(
    input clk_sys,
    input rst_n,
    input in_valid,
    output in_ready,
    input [2:0] adc_channel,  // 请求前由管理器选好并保持；0=ADCV，1=ADCT
    input out_ready,
    output out_valid,
    output [13:0] sample_code,
    output sample_error,
    output adc_error
);
    localparam integer REQUEST_TICKS = 2 * ADC_CLK_DIV;
    localparam integer TIMER_MAX = (ADC_STARTUP_TICKS > REQUEST_TICKS) ? ADC_STARTUP_TICKS : REQUEST_TICKS;
    localparam integer TIMER_W = (TIMER_MAX < 2) ? 1 : $clog2(TIMER_MAX + 64'd1);
    localparam integer WAIT_W = (ADC_TIMEOUT_TICKS < 2) ? 1 : $clog2(ADC_TIMEOUT_TICKS + 64'd1);
    localparam integer SAMPLE_COUNT = 64 << SAMPLE_COUNT_SEL;
    localparam integer SAMPLE_RATE = 4 << RATE_CHANGE_SEL;
    localparam integer ADC_PHASE_W = (ADC_CLK_DIV < 2) ? 1 : $clog2(ADC_CLK_DIV);
    localparam [2:0] S_STARTUP = 3'd0, S_IDLE = 3'd1,
                     S_REQUEST = 3'd2, S_WAIT = 3'd3, S_RECOVER = 3'd4;
    wire [2:0] stc;
    reg [2:0] stn;
    wire clk_adc;
    reg clk_adc_r;
    reg [ADC_PHASE_W-1:0] adc_phase_r;
    wire adc_ready;
    wire adc_ready_sync;
    wire [13:0] adc_value;
    wire adc_reset_n;
    wire wait_active;
    wire timed_out;
    reg adc_reset_release_r;
    reg adc_request_r;
    reg busy_seen_r;
    reg out_valid_r;
    reg [13:0] sample_code_r;
    reg sample_error_r;
    reg adc_error_r;
    reg [TIMER_W-1:0] timer_r;
    reg [WAIT_W-1:0] wait_r;

    assign in_ready = rst_n && (stc == S_IDLE) && (!out_valid_r || out_ready);
    assign out_valid = out_valid_r;
    assign sample_code = sample_code_r;
    assign sample_error = sample_error_r;
    assign adc_error = adc_error_r;
    assign adc_reset_n = rst_n && adc_reset_release_r;
    assign wait_active = (stc == S_REQUEST) || (stc == S_WAIT);
    assign timed_out = (wait_r >= ADC_TIMEOUT_TICKS - 1);

    assign clk_adc = clk_adc_r;

    // clk_adc_r的D端只由相位计数器决定，不用~clk_adc_r形成生成时钟反馈数据路径。
    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            adc_phase_r <= '0;
            clk_adc_r <= 1'b0;
        end
        else
        begin
            if (adc_phase_r == ADC_CLK_DIV - 1)
                adc_phase_r <= '0;
            else
                adc_phase_r <= adc_phase_r + 1'b1;
            // 不能译码“下一相位”，否则综合可能把此寄存器与相位计数器MSB折叠。
            clk_adc_r <= (adc_phase_r >= ADC_CLK_DIV / 2);
        end
    end

    // 仅硬IP使用分频时钟；模拟专用管脚由硬核隐式连接。
    ADCLRC #(
        .DYN_BKEN("FALSE"),
        .CLK_SEL(1'b1),
        .PIOCLK_SEL(1'b0),
        .DIV_CTL(2'd0),
        .VSEN_CTL(3'b000),
        .VSEN_CTL_SEL(1'b1),
        .ADC_MODE(1'b1),
        .SAMPLE_CNT_SEL(SAMPLE_COUNT_SEL),
        .RATE_CHANGE_CTRL(RATE_CHANGE_SEL)
    ) adc_u (
        .ADCINBK2A(1'b0), .ADCINBK2B(1'b0),
        .ADCINBK3A(1'b0), .ADCINBK3B(1'b0),
        .ADCINBK4A(1'b0), .ADCINBK4B(1'b0),
        .ADCINBK5A(1'b0), .ADCINBK5B(1'b0),
        .VSENCTL(adc_channel),
        .FSCAL_VALUE(FSCAL_VALUE),
        .OFFSET_VALUE(OFFSET_VALUE),
        .ADCEN(rst_n),
        .CLK(clk_adc),
        .DRSTN(adc_reset_n),
        .ADCREQI(adc_request_r),
        .ADCRDY(adc_ready),
        .ADCVALUE(adc_value)
    );

    signal_sync #(
        .W(1),
        .INITIAL_VALUE(1'b0)
    ) adc_ready_sync_u (
        .clk(clk_sys),
        .rst_n(rst_n),
        .signal_in(adc_ready),
        .signal_out(adc_ready_sync)
    );

    fsm #(
        .W(3),
        .INITIAL_STATE(S_STARTUP)
    ) fsm_u (
        .clk(clk_sys), .rst_n(rst_n), .stn(stn), .stc(stc)
    );

    always @(*)
    begin
        case (stc)
            S_STARTUP: stn = (timer_r == ADC_STARTUP_TICKS - 1) ? S_IDLE : S_STARTUP;
            S_IDLE: stn = (in_valid && in_ready) ? S_REQUEST : S_IDLE;
            S_REQUEST: stn = timed_out ? S_RECOVER :
                             ((timer_r == REQUEST_TICKS - 1) ? S_WAIT : S_REQUEST);
            S_WAIT: stn = timed_out ? S_RECOVER :
                          ((busy_seen_r && adc_ready_sync) ? S_IDLE : S_WAIT);
            S_RECOVER: stn = (timer_r == REQUEST_TICKS - 1) ? S_STARTUP : S_RECOVER;
            default: stn = S_RECOVER;
        endcase
    end

    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            adc_reset_release_r <= 1'b0;
            adc_request_r <= 1'b0;
            busy_seen_r <= 1'b0;
            out_valid_r <= 1'b0;
            sample_code_r <= 14'd0;
            sample_error_r <= 1'b0;
            adc_error_r <= 1'b0;
            timer_r <= '0;
            wait_r <= '0;
        end
        else
        begin
            sample_error_r <= 1'b0;
            if (out_valid_r && out_ready)
                out_valid_r <= 1'b0;
            if (wait_active)
            begin
                if (!timed_out)
                    wait_r <= wait_r + 1'b1;
                if (!adc_ready_sync)
                    busy_seen_r <= 1'b1;
            end
            else
                wait_r <= '0;

            if (wait_active && timed_out)
            begin
                adc_request_r <= 1'b0;
                adc_reset_release_r <= 1'b0;
                sample_error_r <= 1'b1;
                adc_error_r <= 1'b1;
                busy_seen_r <= 1'b0;
                timer_r <= '0;
            end
            else
            begin
                case (stc)
                    S_STARTUP:
                    begin
                        adc_reset_release_r <= 1'b1;
                        if (timer_r == ADC_STARTUP_TICKS - 1)
                            timer_r <= '0;
                        else
                            timer_r <= timer_r + 1'b1;
                    end
                    S_IDLE:
                    begin
                        timer_r <= '0;
                        if (in_valid && in_ready)
                        begin
                            adc_request_r <= 1'b1;
                            // 上一转换可能让ready维持高；必须观察本次请求的busy低电平。
                            busy_seen_r <= 1'b0;
                        end
                    end
                    S_REQUEST:
                    begin
                        if (timer_r == REQUEST_TICKS - 1)
                        begin
                            timer_r <= '0;
                            adc_request_r <= 1'b0;
                        end
                        else
                            timer_r <= timer_r + 1'b1;
                    end
                    S_WAIT:
                    begin
                        if (busy_seen_r && adc_ready_sync)
                        begin
                            // ready经两级同步，ADCVALUE保持至下次转换，整组捕获稳定总线。
                            sample_code_r <= adc_value;
                            out_valid_r <= 1'b1;
                        end
                    end
                    S_RECOVER:
                    begin
                        adc_request_r <= 1'b0;
                        adc_reset_release_r <= 1'b0;
                        if (timer_r == REQUEST_TICKS - 1)
                        begin
                            timer_r <= '0;
                            adc_reset_release_r <= 1'b1;
                        end
                        else
                            timer_r <= timer_r + 1'b1;
                    end
                    default:
                    begin
                        adc_request_r <= 1'b0;
                        adc_reset_release_r <= 1'b0;
                        timer_r <= '0;
                    end
                endcase
            end
        end
    end

    // synthesis translate_off
    initial
    begin
        if (SYS_CLK_HZ <= 0 || ADC_CLK_DIV < 4 || ADC_CLK_DIV % 2 != 0 ||
            SYS_CLK_HZ < 64'd500000 * ADC_CLK_DIV ||
            SYS_CLK_HZ >= 64'd2000000 * ADC_CLK_DIV)
            $fatal(1, "keyboard_adc: require even divider>=4 and 0.5MHz<=ADC clock<2MHz");
        if (ADC_STARTUP_TICKS < REQUEST_TICKS || ADC_TIMEOUT_TICKS < 4096 * ADC_CLK_DIV)
            $fatal(1, "keyboard_adc: startup/timeout too short");
        if (SAMPLE_COUNT_SEL < 1 || SAMPLE_COUNT_SEL > 4 || RATE_CHANGE_SEL < 2 ||
            RATE_CHANGE_SEL > 5 || SAMPLE_COUNT <= 7 * SAMPLE_RATE)
            $fatal(1, "keyboard_adc: invalid CIC sample count/rate");
        if (FSCAL_VALUE < 452 || FSCAL_VALUE > 840)
            $fatal(1, "keyboard_adc: invalid voltage-mode full-scale calibration");
        if ($signed(OFFSET_VALUE) < -410 || $signed(OFFSET_VALUE) > 410)
            $fatal(1, "keyboard_adc: invalid voltage-mode signed offset calibration");
    end
    // synthesis translate_on
endmodule
