/**
 * 双片4067共用一路ADC，顺序扫描全部24个FSR并输出逐键校准后的完整压力帧。
 */
/**
 * scan_tick_up: 空闲且ADC就绪时启动24通道一帧；忙时忽略tick。
 * mux_addr[0..3]: 共接两片的S0..S3，S0最低位；mux_en_a_n/mux_en_b_n分别接低有效EN。
 * 第一片Y0..Y15对应键0..15；第二片Y0..Y7对应键16..23，第二片Y8..Y15不扫描。
 * 改地址前两片全部关闭，等待BREAK，再改地址、等待SETUP、仅使能目标片、等待SETTLE。
 * MUX_BREAK_TICKS/ADDRESS_SETUP_TICKS/MUX_SETTLE_TICKS: 系统周期数。
 * ADC_DISCARD_SAMPLES: 每次切换通道后丢弃的完整转换次数，默认1。
 * ZERO_CODES/FULL_CODES: 每键14位码，最低14位对应键0；24个键分别校准。
 * DEAD_BAND_CODE: 零点以上死区码；扣除零点/死区后线性映射并饱和到UQ0.16。
 * 默认0/1690对应松开高阻、10kΩ下拉、1/4缩放；正常重压端点须实测逐键校准。
 * frame_done: 一拍完成通知，不是valid/ready接口；此时velocity全部来自最近完整轮询。
 * 轮询期间velocity可逐项更新，调用者只能在frame_done时整组捕获，不可直接连接UI。
 * ADC故障丢弃半帧并关闭两片4067；调用者保留上次完整帧，恢复后从键0重新采集。
 * KEY_NUM固定24；SYS_CLK_HZ单位Hz，其余时序参数为系统周期数。
 */
module keyboard_pressure_scanner
#(
    parameter integer KEY_NUM = 24,
    parameter integer SYS_CLK_HZ = 98_304_000,
    parameter integer ADC_CLK_DIV = 64,
    parameter integer ADC_STARTUP_TICKS = 98_304,
    parameter integer ADC_TIMEOUT_TICKS = 4096 * ADC_CLK_DIV,
    parameter integer ADC_SAMPLE_COUNT_SEL = 1,
    parameter integer ADC_RATE_CHANGE_SEL = 2,
    parameter integer MUX_BREAK_TICKS = 16,
    parameter integer ADDRESS_SETUP_TICKS = 16,
    parameter integer MUX_SETTLE_TICKS = 4916,
    parameter integer ADC_DISCARD_SAMPLES = 1,
    parameter [KEY_NUM*14-1:0] ZERO_CODES = {KEY_NUM{14'd0}},
    parameter [KEY_NUM*14-1:0] FULL_CODES = {KEY_NUM{14'd1690}},
    parameter integer DEAD_BAND_CODE = 8,
    parameter [9:0] ADC_FSCAL_VALUE = 10'd653,
    parameter [11:0] ADC_OFFSET_VALUE = 12'd0
)(
    input clk_sys,
    input rst_n,
    input scan_tick_up,
    output [3:0] mux_addr,
    output mux_en_a_n,
    output mux_en_b_n,
    output [15:0] velocity [KEY_NUM-1:0],
    output frame_done,
    output adc_error
);
    localparam integer WAIT_MAX1 = (MUX_BREAK_TICKS > ADDRESS_SETUP_TICKS) ? MUX_BREAK_TICKS : ADDRESS_SETUP_TICKS;
    localparam integer WAIT_MAX = (WAIT_MAX1 > MUX_SETTLE_TICKS) ? WAIT_MAX1 : MUX_SETTLE_TICKS;
    localparam integer TIMER_W = (WAIT_MAX < 2) ? 1 : $clog2(WAIT_MAX + 64'd1);
    localparam integer DISCARD_W = (ADC_DISCARD_SAMPLES < 1) ? 1 : $clog2(ADC_DISCARD_SAMPLES + 64'd1);
    localparam [3:0] S_IDLE = 4'd0, S_BREAK = 4'd1, S_ADDRESS = 4'd2,
                     S_SETTLE = 4'd3, S_REQUEST = 4'd4, S_WAIT = 4'd5,
                     S_DISTANCE = 4'd6, S_SCALE = 4'd7, S_STORE = 4'd8,
                     S_NEXT = 4'd9;
    wire [3:0] stc;
    reg [3:0] stn;
    reg [4:0] channel_index_r;
    wire [4:0] key_id;
    reg [TIMER_W-1:0] timer_r;
    reg [DISCARD_W-1:0] discarded_r;
    reg [3:0] mux_addr_r;
    reg mux_en_a_n_r;
    reg mux_en_b_n_r;
    reg frame_done_r;
    reg [13:0] raw_code_r;
    reg [13:0] distance_r;
    reg [1:0] region_r;
    reg [45:0] product_r;
    reg [15:0] velocity_r [KEY_NUM-1:0];
    wire [13:0] low_code [KEY_NUM-1:0];
    wire [13:0] full_code [KEY_NUM-1:0];
    wire [31:0] gain [KEY_NUM-1:0];
    wire [45:0] rounded_product;
    wire request_valid, request_ready;
    wire result_valid, result_ready;
    wire [13:0] result_code;
    wire sample_error;
    integer i;
    genvar key;

    assign mux_addr = mux_addr_r;
    assign mux_en_a_n = mux_en_a_n_r;
    assign mux_en_b_n = mux_en_b_n_r;
    assign key_id = channel_index_r;
    assign frame_done = frame_done_r;
    assign request_valid = (stc == S_REQUEST);
    assign result_ready = (stc == S_WAIT);
    assign rounded_product = product_r + 46'd32768;

    generate
        for (key = 0; key < KEY_NUM; key = key + 1)
        begin : g_key_calibration
            localparam integer LOW_CODE = ZERO_CODES[key*14 +: 14] + DEAD_BAND_CODE;
            localparam integer FULL_CODE = FULL_CODES[key*14 +: 14];
            localparam integer SPAN = (FULL_CODE > LOW_CODE) ? FULL_CODE - LOW_CODE : 1;
            // Q16倒数系数在elaboration时计算，运行时只有减法、乘法和移位。
            localparam [31:0] GAIN = (64'd4294901760 + SPAN / 2) / SPAN;
            assign low_code[key] = LOW_CODE;
            assign full_code[key] = FULL_CODE;
            assign gain[key] = GAIN;
            assign velocity[key] = velocity_r[key];
            // synthesis translate_off
            initial
            begin
                if (DEAD_BAND_CODE < 0 || LOW_CODE >= FULL_CODE || FULL_CODE > 2048)
                    $fatal(1, "keyboard_pressure_scanner: invalid calibration at key %0d", key);
            end
            // synthesis translate_on
        end
    endgenerate

    keyboard_adc #(
        .SYS_CLK_HZ(SYS_CLK_HZ), .ADC_CLK_DIV(ADC_CLK_DIV),
        .ADC_STARTUP_TICKS(ADC_STARTUP_TICKS), .ADC_TIMEOUT_TICKS(ADC_TIMEOUT_TICKS),
        .SAMPLE_COUNT_SEL(ADC_SAMPLE_COUNT_SEL), .RATE_CHANGE_SEL(ADC_RATE_CHANGE_SEL),
        .FSCAL_VALUE(ADC_FSCAL_VALUE), .OFFSET_VALUE(ADC_OFFSET_VALUE)
    ) keyboard_adc_u (
        .clk_sys(clk_sys), .rst_n(rst_n),
        .in_valid(request_valid), .in_ready(request_ready),
        .out_ready(result_ready), .out_valid(result_valid), .sample_code(result_code),
        .sample_error(sample_error), .adc_error(adc_error)
    );

    fsm #(
        .W(4), .INITIAL_STATE(S_IDLE)
    ) fsm_u (
        .clk(clk_sys), .rst_n(rst_n), .stn(stn), .stc(stc)
    );

    always @(*)
    begin
        if (sample_error)
            stn = S_IDLE;
        else
        begin
            case (stc)
                S_IDLE: stn = (scan_tick_up && request_ready) ? S_BREAK : S_IDLE;
                S_BREAK: stn = (timer_r == MUX_BREAK_TICKS - 1) ? S_ADDRESS : S_BREAK;
                S_ADDRESS: stn = (timer_r == ADDRESS_SETUP_TICKS - 1) ? S_SETTLE : S_ADDRESS;
                S_SETTLE: stn = (timer_r == MUX_SETTLE_TICKS - 1) ? S_REQUEST : S_SETTLE;
                S_REQUEST: stn = request_ready ? S_WAIT : S_REQUEST;
                S_WAIT: stn = result_valid ? ((discarded_r < ADC_DISCARD_SAMPLES) ? S_REQUEST : S_DISTANCE) : S_WAIT;
                S_DISTANCE: stn = S_SCALE;
                S_SCALE: stn = S_STORE;
                S_STORE: stn = S_NEXT;
                S_NEXT: stn = (channel_index_r == KEY_NUM - 1) ? S_IDLE : S_BREAK;
                default: stn = S_IDLE;
            endcase
        end
    end

    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            channel_index_r <= 5'd0;
            timer_r <= '0;
            discarded_r <= '0;
            mux_addr_r <= 4'd0;
            mux_en_a_n_r <= 1'b1;
            mux_en_b_n_r <= 1'b1;
            frame_done_r <= 1'b0;
            raw_code_r <= 14'd0;
            distance_r <= 14'd0;
            region_r <= 2'd0;
            product_r <= 46'd0;
            for (i = 0; i < KEY_NUM; i = i + 1)
                velocity_r[i] <= 16'd0;
        end
        else
        begin
            frame_done_r <= 1'b0;
            if (sample_error)
            begin
                mux_en_a_n_r <= 1'b1;
                mux_en_b_n_r <= 1'b1;
                channel_index_r <= 5'd0;
                timer_r <= '0;
                discarded_r <= '0;
            end
            else
            begin
                case (stc)
                    S_IDLE:
                    begin
                        mux_en_a_n_r <= 1'b1;
                        mux_en_b_n_r <= 1'b1;
                        channel_index_r <= 5'd0;
                        timer_r <= '0;
                        discarded_r <= '0;
                    end
                    S_BREAK:
                    begin
                        mux_en_a_n_r <= 1'b1;
                        mux_en_b_n_r <= 1'b1;
                        if (timer_r == MUX_BREAK_TICKS - 1)
                        begin
                            mux_addr_r <= channel_index_r[3:0];
                            timer_r <= '0;
                        end
                        else
                            timer_r <= timer_r + 1'b1;
                    end
                    S_ADDRESS:
                    begin
                        if (timer_r == ADDRESS_SETUP_TICKS - 1)
                        begin
                            // 0..15选择A片，16..23选择B片；两使能始终互斥。
                            mux_en_a_n_r <= channel_index_r[4];
                            mux_en_b_n_r <= ~channel_index_r[4];
                            timer_r <= '0;
                        end
                        else
                            timer_r <= timer_r + 1'b1;
                    end
                    S_SETTLE:
                    begin
                        if (timer_r == MUX_SETTLE_TICKS - 1)
                            timer_r <= '0;
                        else
                            timer_r <= timer_r + 1'b1;
                    end
                    S_WAIT:
                    begin
                        if (result_valid)
                        begin
                            if (discarded_r < ADC_DISCARD_SAMPLES)
                                discarded_r <= discarded_r + 1'b1;
                            else
                                raw_code_r <= result_code;
                        end
                    end
                    S_DISTANCE:
                    begin
                        distance_r <= 14'd0;
                        if (raw_code_r <= low_code[key_id])
                            region_r <= 2'd0;
                        else if (raw_code_r >= full_code[key_id])
                            region_r <= 2'd2;
                        else
                        begin
                            region_r <= 2'd1;
                            distance_r <= raw_code_r - low_code[key_id];
                        end
                    end
                    S_SCALE: product_r <= distance_r * gain[key_id];
                    S_STORE:
                    begin
                        if (region_r == 2'd0)
                            velocity_r[key_id] <= 16'h0000;
                        else if (region_r == 2'd2 || rounded_product[45:16] >= 30'd65535)
                            velocity_r[key_id] <= 16'hFFFF;
                        else
                            velocity_r[key_id] <= rounded_product[31:16];
                    end
                    S_NEXT:
                    begin
                        mux_en_a_n_r <= 1'b1;
                        mux_en_b_n_r <= 1'b1;
                        timer_r <= '0;
                        discarded_r <= '0;
                        if (channel_index_r == KEY_NUM - 1)
                            frame_done_r <= 1'b1;
                        else
                            channel_index_r <= channel_index_r + 1'b1;
                    end
                    S_REQUEST: timer_r <= '0;
                    default:
                    begin
                        mux_en_a_n_r <= 1'b1;
                        mux_en_b_n_r <= 1'b1;
                        timer_r <= '0;
                    end
                endcase
            end
        end
    end

    // synthesis translate_off
    initial
    begin
        if (KEY_NUM != 24 || MUX_BREAK_TICKS < 1 || ADDRESS_SETUP_TICKS < 1 ||
            MUX_SETTLE_TICKS < 1 || ADC_DISCARD_SAMPLES < 0)
            $fatal(1, "keyboard_pressure_scanner: invalid channel count or mux timing");
    end
    // synthesis translate_on
endmodule
