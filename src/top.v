/**
 * 顶层模块
 */


module top
(
    input clk_core,
    input rst_n,
    output clk_sys,
    output clk_i2s,
    output clk_smp,
    output clk_scan,
    output rst_sys_n
);
    clock clk_u
    (
        .clk_core(clk_core),
        .rst_n(rst_n),
        .clk_sys(clk_sys),
        .clk_i2s(clk_i2s),
        .clk_smp(clk_smp),
        .clk_scan(clk_scan),
        .rst_sys_n(rst_sys_n)
    );
endmodule
