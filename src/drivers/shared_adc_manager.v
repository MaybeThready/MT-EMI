/**
 * 单个ADCLRC的双客户端仲裁：压力使用ADCV，弯音轮使用ADCT。
 * 每次先锁存请求方和通道、等待模拟通道稳定，再由keyboard_adc完成转换。
 */
/**
 * 所有接口均在clk_sys上升沿按valid && ready握手；结果在背压下保持。
 * pressure_*和bend_*每次各请求一个14位电压码；请求方负责切换外部模拟MUX并丢弃首样。
 * SETTLE_TICKS是ADCV/ADCT切换后的额外等待，默认约50us。
 * sample_error是对应请求方的单拍超时，adc_error为复位前保持的故障标志。
 */
module shared_adc_manager
#(
    parameter integer SETTLE_TICKS = 4916,
    parameter integer ADC_STARTUP_TICKS = 98304
)(
    input clk_sys,
    input rst_n,
    input pressure_req_valid,
    output pressure_req_ready,
    output pressure_result_valid,
    input pressure_result_ready,
    output [13:0] pressure_result_code,
    output pressure_sample_error,
    input bend_req_valid,
    output bend_req_ready,
    output bend_result_valid,
    input bend_result_ready,
    output [13:0] bend_result_code,
    output bend_sample_error,
    output adc_error
);
    localparam [1:0] S_IDLE = 2'd0, S_SETTLE = 2'd1,
                     S_REQUEST = 2'd2, S_RESULT = 2'd3;
    localparam integer TIMER_W = (SETTLE_TICKS < 2) ? 1 : $clog2(SETTLE_TICKS);
    reg [1:0] state_r;
    reg [TIMER_W-1:0] settle_count_r;
    reg owner_bend_r;
    reg last_owner_bend_r;
    reg channel_known_r;
    wire adc_in_ready, adc_out_valid, adc_out_ready;
    wire [13:0] adc_code;
    wire sample_error;

    // 同一方紧接着重试时保持通道，使“丢弃旧样本＋读取有效样本”不被另一方插入。
    // 两次有效采样之间各驱动都有等待，另一方可在该空档取得硬核。
    wire select_bend = bend_req_valid && (!pressure_req_valid || last_owner_bend_r);
    assign pressure_req_ready = rst_n && (state_r == S_IDLE) && !select_bend;
    assign bend_req_ready = rst_n && (state_r == S_IDLE) && select_bend;
    assign pressure_result_valid = (state_r == S_RESULT) && !owner_bend_r && adc_out_valid;
    assign bend_result_valid = (state_r == S_RESULT) && owner_bend_r && adc_out_valid;
    assign pressure_result_code = adc_code;
    assign bend_result_code = adc_code;
    assign pressure_sample_error = sample_error && !owner_bend_r;
    assign bend_sample_error = sample_error && owner_bend_r;
    assign adc_out_ready = (state_r == S_RESULT) &&
                           (owner_bend_r ? bend_result_ready : pressure_result_ready);

    keyboard_adc #(.ADC_STARTUP_TICKS(ADC_STARTUP_TICKS)) keyboard_adc_u (
        .clk_sys(clk_sys), .rst_n(rst_n), .adc_channel({2'd0, owner_bend_r}),
        .in_valid(state_r == S_REQUEST), .in_ready(adc_in_ready),
        .out_valid(adc_out_valid), .out_ready(adc_out_ready),
        .sample_code(adc_code), .sample_error(sample_error), .adc_error(adc_error)
    );

    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            state_r <= S_IDLE;
            settle_count_r <= '0;
            owner_bend_r <= 1'b0;
            last_owner_bend_r <= 1'b1;
            channel_known_r <= 1'b0;
        end
        else
        begin
            case (state_r)
                S_IDLE:
                begin
                    if ((pressure_req_valid && pressure_req_ready) ||
                        (bend_req_valid && bend_req_ready))
                    begin
                        owner_bend_r <= select_bend;
                        channel_known_r <= 1'b1;
                        state_r <= (channel_known_r && (select_bend == last_owner_bend_r)) ?
                                   S_REQUEST : S_SETTLE;
                        last_owner_bend_r <= select_bend;
                        settle_count_r <= '0;
                    end
                end
                S_SETTLE:
                begin
                    if (settle_count_r == SETTLE_TICKS - 1)
                        state_r <= S_REQUEST;
                    else
                        settle_count_r <= settle_count_r + 1'b1;
                end
                S_REQUEST:
                begin
                    if (adc_in_ready)
                        state_r <= S_RESULT;
                end
                S_RESULT:
                begin
                    if (sample_error || (adc_out_valid && adc_out_ready))
                        state_r <= S_IDLE;
                end
                default: state_r <= S_IDLE;
            endcase
        end
    end

    // synthesis translate_off
    initial
    begin
        if (SETTLE_TICKS < 1)
            $fatal(1, "shared_adc_manager: SETTLE_TICKS must be positive");
    end
    // synthesis translate_on
endmodule
