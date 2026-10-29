/**
 * Tang Mega 138K Pro 内置 ADC 弯音轮驱动
 */

/**
 * clk_sys / rst_n: 系统时钟 / 低有效异步复位；业务逻辑均使用 clk_sys。
 * scan_tick_up: 已同步的单周期扫描脉冲；空闲时启动采集，并发布最近完整组的位置。
 * out_valid && out_ready: 在 clk_sys 上升沿交付一组 bend_value；背压时输出保持。
 * bend_value: UQ0.16，底端 0000、回中 8000、顶端 FFFF；音高换算由 UI 层调用映射器完成。
 * adc_error: 转换超时的锁存标志，复位清除；故障时保留上次完整组，复位 ADC 后重新采集。
 *
 * 模拟输入由 ADCLRC 硬核直接连接专用引脚，不是普通 HDL 数字输入：
 *   通道 0 / ADCV: 电压接 J3.1(N12)，J3.3(P11) 接模拟地，J3.2/4 为 GND。
 *   通道 1 / ADCT: 电压接 J4.3(R12)，J4.1(R11) 接模拟地，J4.2/4 为 GND。
 * 单端输入必须在 0..1V 内；不要给这几根专用引脚设置 LVCMOS33。
 * ADCLRC 输出虽为 14 位，但有效精度约 10 位；电压码 / 2048 = 电压(V)。
 * 参考本机 Gowin V1.9.12.04 的 UG299-1.0.6E：电压输出为无符号值。
 *
 * BEND_NUM: 1..2，只实例化一个 ADCLRC，按 ADCV、ADCT 顺序轮询。
 * SYS_CLK_HZ / ADC_CLK_DIV: 系统频率(Hz) / ADC 偶数分频比；默认 ADC 时钟 1.536MHz。
 * ADC_STARTUP_TICKS: 使能后的额外稳定等待，单位系统周期；默认约 1ms，属于实现裕量。
 * ADC_TIMEOUT_TICKS: 一次请求等待上限，默认 4096 个 ADC 时钟周期。
 * DEBOUNCE_TICKS: 两组采集开始的最小间隔，单位系统周期；默认约 1ms。
 *   模拟控件持续移动时仍更新，不要求同一个电压码保持 DEBOUNCE_TICKS。
 * FILTER_SHIFT: 一阶低通更新比例 1/(2^FILTER_SHIFT)，0 关闭平滑；默认 2。
 * ADC_MIN_CODE / ADC_CENTER_CODE / ADC_MAX_CODE: 实测低/中/高位置电压码，默认 0/1024/2048。
 * CENTER_DEADBAND: 中心左右各自的电压码死区，默认 8，约 3.9mV；两侧重新线性拉伸。
 * DIRECTION_INVERT: 每路方向反转位；中心仍精确输出 8000。
 * 背压只冻结待交付快照，不阻塞采集；恢复后按扫描节拍发送最新完整组，不缓存历史轨迹。
 */
module pitch_bend_driver
#(
    parameter integer BEND_NUM = 1,
    parameter integer DEBOUNCE_TICKS = 98304,
    parameter integer SYS_CLK_HZ = 98304000,
    parameter integer ADC_CLK_DIV = 64,
    parameter integer ADC_STARTUP_TICKS = 98304,
    parameter integer ADC_TIMEOUT_TICKS = 4096 * ADC_CLK_DIV,
    parameter integer FILTER_SHIFT = 2,
    parameter integer ADC_MIN_CODE = 0,
    parameter integer ADC_CENTER_CODE = 1024,
    parameter integer ADC_MAX_CODE = 2048,
    parameter integer CENTER_DEADBAND = 8,
    parameter [BEND_NUM-1:0] DIRECTION_INVERT = 0
)(
    input clk_sys,
    input rst_n,
    input scan_tick_up,
    input out_ready,
    output [15:0] bend_value [BEND_NUM-1:0],
    output out_valid,
    output adc_error
);
    localparam [3:0] S_POWER_SETTLE = 4'd0,
                     S_WAIT_SCAN = 4'd1,
                     S_SELECT_INPUT = 4'd2,
                     S_REQUEST_ADC = 4'd3,
                     S_WAIT_BUSY = 4'd4,
                     S_WAIT_RESULT = 4'd5,
                     S_FILTER = 4'd6,
                     S_FORM_DISTANCE = 4'd7,
                     S_SCALE_DISTANCE = 4'd8,
                     S_NORMALIZE = 4'd9,
                     S_NEXT_INPUT = 4'd10,
                     S_RECOVER_ADC = 4'd11;

    localparam [2:0] N_BOTTOM = 3'd0,
                     N_BELOW_CENTER = 3'd1,
                     N_CENTER = 3'd2,
                     N_ABOVE_CENTER = 3'd3,
                     N_TOP = 3'd4;

    localparam integer REQUEST_TICKS = 2 * ADC_CLK_DIV;
    localparam integer TIMER_MAX = (ADC_STARTUP_TICKS > REQUEST_TICKS) ?
                                  ADC_STARTUP_TICKS : REQUEST_TICKS;
    localparam integer TIMER_W = (TIMER_MAX > 1) ? $clog2(TIMER_MAX) : 1;
    localparam integer WAIT_W = (ADC_TIMEOUT_TICKS > 1) ? $clog2(ADC_TIMEOUT_TICKS) : 1;
    localparam integer INTERVAL_W = (DEBOUNCE_TICKS > 0) ? $clog2(DEBOUNCE_TICKS + 1) : 1;
    localparam integer CENTER_LOW = ADC_CENTER_CODE - CENTER_DEADBAND;
    localparam integer CENTER_HIGH = ADC_CENTER_CODE + CENTER_DEADBAND;
    // 常量除法仅在 elaboration 时计算；Q16 倒数系数用于运行时乘法归一化。
    localparam [31:0] LOWER_GAIN = (64'd2147483648 + (CENTER_LOW - ADC_MIN_CODE) / 2) /
                                  ((CENTER_LOW > ADC_MIN_CODE) ? (CENTER_LOW - ADC_MIN_CODE) : 1);
    localparam [31:0] UPPER_GAIN = (64'd2147418112 + (ADC_MAX_CODE - CENTER_HIGH) / 2) /
                                  ((ADC_MAX_CODE > CENTER_HIGH) ? (ADC_MAX_CODE - CENTER_HIGH) : 1);

    wire [3:0] stc;
    reg [3:0] stn;
    wire clk_adc;
    wire adc_ready;
    wire adc_ready_sync;
    wire adc_reset_n;
    wire [13:0] adc_value;
    wire adc_wait_active;
    wire adc_timed_out;
    wire interval_elapsed;
    reg adc_reset_release_r;
    reg adc_request_r;
    reg adc_error_r;
    reg input_index_r;
    reg [TIMER_W-1:0] timer_r;
    reg [WAIT_W-1:0] adc_wait_r;
    reg [INTERVAL_W-1:0] interval_r;
    reg [13:0] raw_code_r;
    reg [2:0] normalization_region_r;
    reg [13:0] normalization_distance_r;
    reg [45:0] normalization_product_r;
    reg [15:0] normalized_position;
    reg [21:0] filtered_code_r [BEND_NUM-1:0];  // ADC 电压码附加 8 位小数，避免平滑舍入滞留。
    reg [BEND_NUM-1:0] filter_initialized_r;
    reg [15:0] normalized_value_r [BEND_NUM-1:0];
    reg [15:0] latest_value_r [BEND_NUM-1:0];
    reg latest_valid_r;
    reg [15:0] bend_value_r [BEND_NUM-1:0];
    reg out_valid_r;
    wire [21:0] target_code;
    wire signed [22:0] filter_difference;
    wire signed [22:0] filter_next;
    wire [22:0] rounded_code;
    wire [13:0] filtered_voltage_code;
    wire [45:0] rounded_product;
    integer bend;
    integer output_lane;

    assign out_valid = out_valid_r;
    assign adc_error = adc_error_r;
    // 硬核异步复位使用寄存信号，不能直接译码多位 FSM 状态，以免出现复位毛刺。
    assign adc_reset_n = rst_n && adc_reset_release_r;
    assign adc_wait_active = (stc == S_REQUEST_ADC) ||
                             (stc == S_WAIT_BUSY) || (stc == S_WAIT_RESULT);
    assign adc_timed_out = (adc_wait_r == ADC_TIMEOUT_TICKS - 1);
    assign interval_elapsed = (interval_r >= DEBOUNCE_TICKS);
    assign target_code = {raw_code_r, 8'd0};
    assign filter_difference = $signed({1'b0, target_code}) -
                               $signed({1'b0, filtered_code_r[input_index_r]});
    assign filter_next = $signed({1'b0, filtered_code_r[input_index_r]}) +
                        (filter_difference >>> FILTER_SHIFT);
    assign rounded_code = {1'b0, filtered_code_r[input_index_r]} + 23'd128;
    assign filtered_voltage_code = rounded_code[21:8];
    assign rounded_product = normalization_product_r + 46'd32768;

    genvar lane;
    generate
        for (lane = 0; lane < BEND_NUM; lane = lane + 1)
        begin: g_output
            assign bend_value[lane] = bend_value_r[lane];
        end
    endgenerate

    clock_divider #(
        .NUM_DIV(ADC_CLK_DIV)
    ) adc_clock_divider_u (
        .clk(clk_sys), .rst_n(rst_n), .clk_div(clk_adc)
    );

    // ADC_CLK 是硬 IP 的专用工作时钟；用户状态机不在该时钟域运行。
    ADCLRC #(
        .DYN_BKEN("FALSE"),
        .BUF_SERDES_Q1_EN(3'b000),
        .BUF_BK2_EN(6'b000000), .BUF_BK3_EN(6'b000000),
        .BUF_BK4_EN(6'b000000), .BUF_BK5_EN(6'b000000),
        .BUF_BK10_EN(5'b00000), .BUF_BK11_EN(5'b00000),
        .CLK_SEL(1'b1), .PIOCLK_SEL(1'b0), .DIV_CTL(2'd0),
        .VSEN_CTL(3'b000), .VSEN_CTL_SEL(1'b1), .ADC_MODE(1'b1),
        .SAMPLE_CNT_SEL(3'd4), .RATE_CHANGE_CTRL(3'd5)
    ) adc_u (
        .ADCINBK2A(1'b0), .ADCINBK2B(1'b0),
        .ADCINBK3A(1'b0), .ADCINBK3B(1'b0),
        .ADCINBK4A(1'b0), .ADCINBK4B(1'b0),
        .ADCINBK5A(1'b0), .ADCINBK5B(1'b0),
        .VSENCTL({2'b00, input_index_r}),
        .FSCAL_VALUE(10'd653), .OFFSET_VALUE(12'd0),
        .ADCEN(rst_n), .CLK(clk_adc), .DRSTN(adc_reset_n),
        .ADCREQI(adc_request_r), .ADCRDY(adc_ready), .ADCVALUE(adc_value)
    );

    signal_sync #(
        .W(1), .INITIAL_VALUE(0)
    ) adc_ready_sync_u (
        .clk(clk_sys), .rst_n(rst_n),
        .signal_in(adc_ready), .signal_out(adc_ready_sync)
    );

    fsm #(
        .W(4), .INITIAL_STATE(S_POWER_SETTLE)
    ) fsm_u (
        .clk(clk_sys), .rst_n(rst_n), .stn(stn), .stc(stc)
    );

    always @(*)
    begin
        case (stc)
            S_POWER_SETTLE:
                stn = (timer_r == ADC_STARTUP_TICKS - 1) ? S_WAIT_SCAN : S_POWER_SETTLE;
            S_WAIT_SCAN:
                stn = (scan_tick_up && interval_elapsed) ? S_SELECT_INPUT : S_WAIT_SCAN;
            S_SELECT_INPUT:
                stn = (timer_r == REQUEST_TICKS - 1) ? S_REQUEST_ADC : S_SELECT_INPUT;
            S_REQUEST_ADC:
                stn = adc_timed_out ? S_RECOVER_ADC :
                      ((timer_r == REQUEST_TICKS - 1) ? S_WAIT_BUSY : S_REQUEST_ADC);
            S_WAIT_BUSY:
                stn = adc_timed_out ? S_RECOVER_ADC :
                      ((!adc_ready_sync) ? S_WAIT_RESULT : S_WAIT_BUSY);
            S_WAIT_RESULT:
                stn = adc_timed_out ? S_RECOVER_ADC :
                      (adc_ready_sync ? S_FILTER : S_WAIT_RESULT);
            S_FILTER:
                stn = S_FORM_DISTANCE;
            S_FORM_DISTANCE:
                stn = S_SCALE_DISTANCE;
            S_SCALE_DISTANCE:
                stn = S_NORMALIZE;
            S_NORMALIZE:
                stn = S_NEXT_INPUT;
            S_NEXT_INPUT:
                stn = (input_index_r == BEND_NUM - 1) ? S_WAIT_SCAN : S_SELECT_INPUT;
            S_RECOVER_ADC:
                stn = (timer_r == REQUEST_TICKS - 1) ? S_POWER_SETTLE : S_RECOVER_ADC;
            default:
                stn = S_POWER_SETTLE;
        endcase
    end

    // 距离、乘法、舍入定位分拍执行，避免归一化形成跨减法和乘法的长路径。
    always @(*)
    begin
        case (normalization_region_r)
            N_BOTTOM: normalized_position = 16'h0000;
            N_BELOW_CENTER: normalized_position = 16'd32768 - rounded_product[31:16];
            N_CENTER: normalized_position = 16'h8000;
            N_ABOVE_CENTER: normalized_position = 16'd32768 + rounded_product[31:16];
            N_TOP: normalized_position = 16'hFFFF;
            default: normalized_position = 16'h8000;
        endcase
    end

    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            timer_r <= '0;
            adc_wait_r <= '0;
            interval_r <= '0;
            adc_request_r <= 1'b0;
            adc_reset_release_r <= 1'b0;
            adc_error_r <= 1'b0;
            input_index_r <= 1'b0;
            raw_code_r <= 14'd0;
            normalization_region_r <= N_CENTER;
            normalization_distance_r <= 14'd0;
            normalization_product_r <= 46'd0;
            filter_initialized_r <= '0;
            latest_valid_r <= 1'b0;
            for (bend = 0; bend < BEND_NUM; bend = bend + 1)
            begin
                filtered_code_r[bend] <= ADC_CENTER_CODE << 8;
                normalized_value_r[bend] <= 16'h8000;
                latest_value_r[bend] <= 16'h8000;
            end
        end
        else
        begin
            if (stc == S_WAIT_SCAN && scan_tick_up && interval_elapsed)
                interval_r <= '0;
            else if (!interval_elapsed)
                interval_r <= interval_r + 1'b1;

            if (adc_wait_active && !adc_timed_out)
                adc_wait_r <= adc_wait_r + 1'b1;
            else
                adc_wait_r <= '0;

            if (adc_wait_active && adc_timed_out)
            begin
                adc_error_r <= 1'b1;
                adc_request_r <= 1'b0;
                adc_reset_release_r <= 1'b0;
                input_index_r <= 1'b0;
                timer_r <= '0;
            end
            else
            begin
                case (stc)
                    S_POWER_SETTLE:
                    begin
                        adc_reset_release_r <= 1'b1;
                        if (timer_r == ADC_STARTUP_TICKS - 1)
                            timer_r <= '0;
                        else
                            timer_r <= timer_r + 1'b1;
                    end
                    S_RECOVER_ADC:
                    begin
                        // 取消超时的旧转换，避免迟到结果被归入下一次请求或另一输入通道。
                        if (timer_r == REQUEST_TICKS - 1)
                        begin
                            timer_r <= '0;
                            adc_reset_release_r <= 1'b1;
                        end
                        else
                            timer_r <= timer_r + 1'b1;
                    end
                    S_WAIT_SCAN:
                    begin
                        timer_r <= '0;
                        input_index_r <= 1'b0;
                    end
                    S_SELECT_INPUT:
                    begin
                        if (timer_r == REQUEST_TICKS - 1)
                        begin
                            timer_r <= '0;
                            adc_request_r <= 1'b1;
                        end
                        else
                            timer_r <= timer_r + 1'b1;
                    end
                    S_REQUEST_ADC:
                    begin
                        if (timer_r == REQUEST_TICKS - 1)
                        begin
                            timer_r <= '0;
                            adc_request_r <= 1'b0;
                        end
                        else
                            timer_r <= timer_r + 1'b1;
                    end
                    S_WAIT_RESULT:
                    begin
                        // ADCRDY 已经两级同步；结果总线从完成起保持到下次转换，可整组锁存。
                        if (adc_ready_sync)
                            raw_code_r <= adc_value;
                    end
                    S_FILTER:
                    begin
                        if (!filter_initialized_r[input_index_r])
                            filtered_code_r[input_index_r] <= target_code;
                        else
                            filtered_code_r[input_index_r] <= filter_next[21:0];
                        filter_initialized_r[input_index_r] <= 1'b1;
                    end
                    S_FORM_DISTANCE:
                    begin
                        normalization_distance_r <= 14'd0;
                        if (filtered_voltage_code <= ADC_MIN_CODE)
                            normalization_region_r <= N_BOTTOM;
                        else if (filtered_voltage_code >= ADC_MAX_CODE)
                            normalization_region_r <= N_TOP;
                        else if (filtered_voltage_code < CENTER_LOW)
                        begin
                            normalization_region_r <= N_BELOW_CENTER;
                            normalization_distance_r <= CENTER_LOW - filtered_voltage_code;
                        end
                        else if (filtered_voltage_code > CENTER_HIGH)
                        begin
                            normalization_region_r <= N_ABOVE_CENTER;
                            normalization_distance_r <= filtered_voltage_code - CENTER_HIGH;
                        end
                        else
                            normalization_region_r <= N_CENTER;
                    end
                    S_SCALE_DISTANCE:
                    begin
                        if (normalization_region_r == N_BELOW_CENTER)
                            normalization_product_r <= normalization_distance_r * LOWER_GAIN;
                        else
                            normalization_product_r <= normalization_distance_r * UPPER_GAIN;
                    end
                    S_NORMALIZE:
                    begin
                        if (DIRECTION_INVERT[input_index_r] && normalized_position != 16'h8000)
                            normalized_value_r[input_index_r] <= 16'hFFFF - normalized_position;
                        else
                            normalized_value_r[input_index_r] <= normalized_position;
                    end
                    S_NEXT_INPUT:
                    begin
                        timer_r <= '0;
                        if (input_index_r == BEND_NUM - 1)
                        begin
                            for (bend = 0; bend < BEND_NUM; bend = bend + 1)
                                latest_value_r[bend] <= normalized_value_r[bend];
                            latest_valid_r <= 1'b1;
                            input_index_r <= 1'b0;
                        end
                        else
                            input_index_r <= input_index_r + 1'b1;
                    end
                    default:
                    begin
                        timer_r <= '0;
                        adc_request_r <= 1'b0;
                    end
                endcase
            end
        end
    end

    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            out_valid_r <= 1'b0;
            for (output_lane = 0; output_lane < BEND_NUM; output_lane = output_lane + 1)
                bend_value_r[output_lane] <= 16'h8000;
        end
        else
        begin
            if (out_valid_r && out_ready)
                out_valid_r <= 1'b0;
            if (scan_tick_up && latest_valid_r && (!out_valid_r || out_ready))
            begin
                for (output_lane = 0; output_lane < BEND_NUM; output_lane = output_lane + 1)
                    bend_value_r[output_lane] <= latest_value_r[output_lane];
                out_valid_r <= 1'b1;
            end
        end
    end

    // synthesis translate_off
    initial
    begin
        if (BEND_NUM < 1 || BEND_NUM > 2 || SYS_CLK_HZ <= 0 || ADC_CLK_DIV < 4 ||
            ADC_CLK_DIV % 2 != 0 || SYS_CLK_HZ >= 64'd2000000 * ADC_CLK_DIV ||
            SYS_CLK_HZ < 64'd500000 * ADC_CLK_DIV)
            $fatal(1, "pitch_bend_driver: BEND_NUM=1..2; even ADC divider >=4 and 0.5MHz <= ADC clock <2MHz required");
        if (ADC_STARTUP_TICKS < REQUEST_TICKS || ADC_TIMEOUT_TICKS < 4096 * ADC_CLK_DIV ||
            DEBOUNCE_TICKS < 0 || FILTER_SHIFT < 0 || FILTER_SHIFT > 8)
            $fatal(1, "pitch_bend_driver: invalid startup, timeout, acquisition interval or filter shift");
        if (ADC_MIN_CODE < 0 || ADC_MAX_CODE > 2048 || CENTER_DEADBAND < 0 ||
            ADC_MIN_CODE >= CENTER_LOW || CENTER_HIGH >= ADC_MAX_CODE)
            $fatal(1, "pitch_bend_driver: require 0 <= MIN < CENTER-DEADBAND <= CENTER+DEADBAND < MAX <= 2048");
    end
    // synthesis translate_on
endmodule
