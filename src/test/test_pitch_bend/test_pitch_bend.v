/**
 * 弯音轮、24键力度与发声链路联合上板测试。
 * 压力ADCV和弯音ADCT由shared_adc_manager分时使用同一ADCLRC硬核。
 * 旋钮不参与本测试；键盘、FSR、I2S和LED引脚与test_velocity保持一致。
 */
/**
 * 弯音轮正端接J4.3/R12(ADCT+)，负端接J4.1/R11(ADCT-)并与模拟地共地。
 * 这两个模拟专用脚由ADCLRC隐式连接，不是普通HDL数字端口，CST不能设置LVCMOS33。
 * ADCT由ADCLRC硬核直接读取，不设置数字顶层端口或IO_LOC。
 * 弯音从0..1V对应-200..+200音分；回中应恢复原音高，力度仍控制音量。
 */
module test_pitch_bend
#(
    parameter integer AUDIO_SHIFT = 2,
    parameter [335:0] PRESSURE_ZERO_CODES = {24{14'd0}},
    parameter [335:0] PRESSURE_FULL_CODES = {24{14'd1690}},
    parameter integer ADC_STARTUP_TICKS = 98304,
    parameter integer MUX_SETTLE_TICKS = 4916,
    parameter integer SHARED_SETTLE_TICKS = 4916,
    parameter integer BEND_SETTLE_TICKS = 4916,
    parameter integer BEND_DEBOUNCE_TICKS = 98304,
    parameter integer BEND_FILTER_SHIFT = 2
)(
    input clk_core,
    input rst_n,
    input data_a,
    input data_b,
    output load_n,
    output key_clk,
    output [3:0] mux_addr,
    output mux_en_a_n,
    output mux_en_b_n,
    output i2s_bclk,
    output i2s_lrck,
    output i2s_dout,
    output sd_mode_n,
    output [5:0] status_led
);
    wire clk_sys, rst_sys_n;

    sys_clocker sys_clocker_u (
        .clk_core(clk_core), .rst_n(rst_n),
        .clk_sys(clk_sys), .rst_sys_n(rst_sys_n)
    );

    test_pitch_bend_core #(
        .AUDIO_SHIFT(AUDIO_SHIFT), .PRESSURE_ZERO_CODES(PRESSURE_ZERO_CODES),
        .PRESSURE_FULL_CODES(PRESSURE_FULL_CODES),
        .ADC_STARTUP_TICKS(ADC_STARTUP_TICKS),
        .MUX_SETTLE_TICKS(MUX_SETTLE_TICKS),
        .SHARED_SETTLE_TICKS(SHARED_SETTLE_TICKS),
        .BEND_SETTLE_TICKS(BEND_SETTLE_TICKS),
        .BEND_DEBOUNCE_TICKS(BEND_DEBOUNCE_TICKS),
        .BEND_FILTER_SHIFT(BEND_FILTER_SHIFT)
    ) test_pitch_bend_core_u (
        .clk_sys(clk_sys), .rst_n(rst_sys_n), .data_a(data_a), .data_b(data_b),
        .load_n(load_n), .key_clk(key_clk), .mux_addr(mux_addr),
        .mux_en_a_n(mux_en_a_n), .mux_en_b_n(mux_en_b_n),
        .i2s_bclk(i2s_bclk), .i2s_lrck(i2s_lrck), .i2s_dout(i2s_dout),
        .sd_mode_n(sd_mode_n), .status_led(status_led)
    );
endmodule

/** 测试核心与板载PLL分离，供ModelSim直接提供clk_sys进行联合回归。 */
module test_pitch_bend_core
#(
    parameter integer MAX_POLYPHONY = 32,
    parameter integer AUDIO_SHIFT = 2,
    parameter [335:0] PRESSURE_ZERO_CODES = {24{14'd0}},
    parameter [335:0] PRESSURE_FULL_CODES = {24{14'd1690}},
    parameter integer ADC_STARTUP_TICKS = 98304,
    parameter integer MUX_SETTLE_TICKS = 4916,
    parameter integer SHARED_SETTLE_TICKS = 4916,
    parameter integer BEND_SETTLE_TICKS = 4916,
    parameter integer BEND_DEBOUNCE_TICKS = 98304,
    parameter integer BEND_FILTER_SHIFT = 2
)(
    input clk_sys,
    input rst_n,
    input data_a,
    input data_b,
    output load_n,
    output key_clk,
    output [3:0] mux_addr,
    output mux_en_a_n,
    output mux_en_b_n,
    output i2s_bclk,
    output i2s_lrck,
    output i2s_dout,
    output sd_mode_n,
    output [5:0] status_led
);
    wire scan_tick_up;
    wire pressure_req_valid, pressure_req_ready, pressure_result_valid;
    wire pressure_result_ready, pressure_sample_error;
    wire [13:0] pressure_result_code;
    wire bend_req_valid, bend_req_ready, bend_result_valid;
    wire bend_result_ready, bend_sample_error, adc_error;
    wire [13:0] bend_result_code;
    wire [15:0] bend_value [0:0];
    wire bend_valid, bend_error;

    test_velocity_core #(
        .MAX_POLYPHONY(MAX_POLYPHONY), .SHARED_ADC(1), .AUDIO_SHIFT(AUDIO_SHIFT),
        .ADC_STARTUP_TICKS(ADC_STARTUP_TICKS), .MUX_SETTLE_TICKS(MUX_SETTLE_TICKS),
        .PRESSURE_ZERO_CODES(PRESSURE_ZERO_CODES),
        .PRESSURE_FULL_CODES(PRESSURE_FULL_CODES)
    ) test_velocity_core_u (
        .clk_sys(clk_sys), .rst_n(rst_n), .scan_tick_out(scan_tick_up),
        .data_a(data_a), .data_b(data_b), .bend_position(bend_value[0]),
        .pressure_adc_req_valid(pressure_req_valid),
        .pressure_adc_req_ready(pressure_req_ready),
        .pressure_adc_result_valid(pressure_result_valid),
        .pressure_adc_result_ready(pressure_result_ready),
        .pressure_adc_result_code(pressure_result_code),
        .pressure_adc_sample_error(pressure_sample_error), .pressure_adc_fault(adc_error),
        .load_n(load_n), .key_clk(key_clk), .mux_addr(mux_addr),
        .mux_en_a_n(mux_en_a_n), .mux_en_b_n(mux_en_b_n),
        .i2s_bclk(i2s_bclk), .i2s_lrck(i2s_lrck), .i2s_dout(i2s_dout),
        .sd_mode_n(sd_mode_n), .status_led(status_led)
    );

    pitch_bend_driver #(
        .ADC_EXTERNAL(1), .ADC_STARTUP_TICKS(ADC_STARTUP_TICKS),
        .DEBOUNCE_TICKS(BEND_DEBOUNCE_TICKS), .FILTER_SHIFT(BEND_FILTER_SHIFT),
        .INPUT_SETTLE_TICKS(BEND_SETTLE_TICKS)
    ) pitch_bend_driver_u (
        .clk_sys(clk_sys), .rst_n(rst_n), .scan_tick_up(scan_tick_up),
        .out_ready(1'b1), .bend_value(bend_value), .out_valid(bend_valid),
        .adc_error(bend_error),
        .adc_req_valid(bend_req_valid), .adc_req_ready(bend_req_ready),
        .adc_result_valid(bend_result_valid), .adc_result_ready(bend_result_ready),
        .adc_result_code(bend_result_code), .adc_sample_error(bend_sample_error),
        .adc_fault(adc_error)
    );

    shared_adc_manager #(
        .SETTLE_TICKS(SHARED_SETTLE_TICKS),
        .ADC_STARTUP_TICKS(ADC_STARTUP_TICKS)
    ) shared_adc_manager_u (
        .clk_sys(clk_sys), .rst_n(rst_n),
        .pressure_req_valid(pressure_req_valid), .pressure_req_ready(pressure_req_ready),
        .pressure_result_valid(pressure_result_valid),
        .pressure_result_ready(pressure_result_ready),
        .pressure_result_code(pressure_result_code),
        .pressure_sample_error(pressure_sample_error),
        .bend_req_valid(bend_req_valid), .bend_req_ready(bend_req_ready),
        .bend_result_valid(bend_result_valid), .bend_result_ready(bend_result_ready),
        .bend_result_code(bend_result_code), .bend_sample_error(bend_sample_error),
        .adc_error(adc_error)
    );
endmodule
