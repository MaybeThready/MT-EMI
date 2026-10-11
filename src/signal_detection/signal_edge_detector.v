/**
 * 信号边缘捕获模块
 */

/**
 * 信号边缘捕获模块
 * signal_sync: 关于 clk 同步的信号
 * signal_posedge: 关于 clk 的信号上跳变检测脉冲
 * signal_negedge: 关于 clk 的信号下跳变检测脉冲
 */
module signal_edge_detector
#(
    parameter W = 1
)(
    input clk,
    input rst_n,
    input [W-1:0] signal_sync,
    output [W-1:0] signal_posedge,
    output [W-1:0] signal_negedge
);
    reg [W-1:0] signal_sync_prev;
    always @(posedge clk or negedge rst_n)
    begin
        if (!rst_n)
        begin
            signal_sync_prev <= '0;
        end
        else
        begin
            signal_sync_prev <= signal_sync;
        end
    end

    assign signal_posedge = signal_sync & ~signal_sync_prev;
    assign signal_negedge = ~signal_sync & signal_sync_prev;
endmodule
