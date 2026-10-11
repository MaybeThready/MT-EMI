/**
 * 时钟模块，负责生成系统中的所有时钟
 */

/**
 * 生成系统中的所有时钟
 */
module clock
(
    input clk_core,  // 50M
    input rst_n,
    output clk_sys,  // 98.304M
    output clk_i2s,  // 1.536M
    output clk_smp,  // 48k
    output clk_scan,  // 12k
    output rst_sys_n  // 系统复位信号
);
    wire lock;
    wire clk_sys_w;
    wire rst_async_n;

    gowin_pll gowin_pll_u
    (
        .clkin(clk_core),
        .init_clk(clk_core),
        .clkout0(clk_sys_w),
        .lock(lock),
        .reset(!rst_n)
    );

    assign clk_sys = clk_sys_w;
    assign rst_async_n = rst_n & lock;

    signal_sync #(
        .W(1),
        .INITIAL_VALUE(0)
    ) rst_sync_u (
        .clk(clk_sys),
        .rst_n(rst_async_n),
        .signal_in(1'b1),
        .signal_out(rst_sys_n)
    );

    clock_divider #(
        .NUM_DIV(64)
    ) div_u1 (
        .clk(clk_sys),
        .rst_n(rst_sys_n),
        .clk_div(clk_i2s)
    );

    clock_divider #(
        .NUM_DIV(2048)
    ) div_u2 (
        .clk(clk_sys),
        .rst_n(rst_sys_n),
        .clk_div(clk_smp)
    );

    clock_divider #(
        .NUM_DIV(8192)
    ) div_u3 (
        .clk(clk_sys),
        .rst_n(rst_sys_n),
        .clk_div(clk_scan)
    );
endmodule
