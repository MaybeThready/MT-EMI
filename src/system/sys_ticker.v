/**
 * Tick 脉冲生成模块
 */

`include "../defines.vh"


module sys_ticker
(
    input clk_sys,
    input rst_n,

    output i2s_tick_up,  // 1.536M
    output i2s_tick_down,
    output smp_tick_up,  // 48k
    output smp_tick_down,
    output scan_tick_up,  // 12k
    output scan_tick_down
);
    localparam NUM_DIV_I2S = `CLK_SYS_FREQ / `I2S_TICK_FREQ;
    localparam NUM_DIV_SMP = `CLK_SYS_FREQ / `SMP_TICK_FREQ;
    localparam NUM_DIV_SCAN = `CLK_SYS_FREQ / `SCAN_TICK_FREQ;

    clock_divider #(
        .NUM_DIV(NUM_DIV_I2S)
    ) div_u1 (
        .clk(clk_sys),
        .rst_n(rst_n),
        .clk_div(clk_i2s)
    );

    clock_divider #(
        .NUM_DIV(NUM_DIV_SMP)
    ) div_u2 (
        .clk(clk_sys),
        .rst_n(rst_n),
        .clk_div(clk_smp)
    );

    clock_divider #(
        .NUM_DIV(NUM_DIV_SCAN)
    ) div_u3 (
        .clk(clk_sys),
        .rst_n(rst_n),
        .clk_div(clk_scan)
    );

    signal_edge_detector #(
        .W(3)
    ) sed_u (
        .clk(clk_sys),
        .rst_n(rst_n),
        .signal_sync({clk_i2s, clk_smp, clk_scan}),
        .signal_posedge({i2s_tick_up, smp_tick_up, scan_tick_up}),
        .signal_negedge({i2s_tick_down, smp_tick_down, scan_tick_down})
    );
endmodule
