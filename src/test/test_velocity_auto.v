/**
 * 24路FSR自动逐键诊断：每2秒选一个键，力度应只控制当前键音量，无需触摸键盘。
 * LED0..4亮灯权值1/2/4/8/16，相加再加1即FSR编号；LED5仍是故障灯。
 * 保留原压力扫描/ADC、UI、机架、I2S模块；仅用单声部减少诊断工程资源。
 * 所有接线与test_velocity相同，S0复位后从FSR1开始，48秒循环。
 */
module test_velocity_auto
(
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
        .clk_core(clk_core), .rst_n(rst_n), .clk_sys(clk_sys), .rst_sys_n(rst_sys_n)
    );

    test_velocity_core #(
        .MAX_POLYPHONY(1), .AUTO_KEY_TEST(1), .AUDIO_SHIFT(1)
    ) test_velocity_core_u (
        .clk_sys(clk_sys), .rst_n(rst_sys_n), .data_a(data_a), .data_b(data_b),
        .load_n(load_n), .key_clk(key_clk), .mux_addr(mux_addr),
        .mux_en_a_n(mux_en_a_n), .mux_en_b_n(mux_en_b_n),
        .i2s_bclk(i2s_bclk), .i2s_lrck(i2s_lrck), .i2s_dout(i2s_dout),
        .sd_mode_n(sd_mode_n), .status_led(status_led)
    );
endmodule
