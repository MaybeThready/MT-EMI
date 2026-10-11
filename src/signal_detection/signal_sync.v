/**
 * 异步信号同步模块
 */

/** 异步信号同步器
 * clk: 时钟信号
 * rst_n: 复位信号，低电平有效
 * signal_in: 输入的异步信号
 * signal_out: 输出的同步信号
 * W: 信号的位宽
 * INITIAL_VALUE: 信号的初始值
 */
module signal_sync
#(
    parameter W = 1,
    parameter INITIAL_VALUE = 0  // 信号初值
)(
    input clk,
    input rst_n,
    input [W-1:0] signal_in,
    output [W-1:0] signal_out
);
    reg [W-1:0] signal_buff1, signal_buff2;
    always @(posedge clk or negedge rst_n)
    begin
        if (!rst_n)
        begin
            signal_buff1 <= INITIAL_VALUE;
            signal_buff2 <= INITIAL_VALUE;
        end
        else
        begin
            signal_buff1 <= signal_in;
            signal_buff2 <= signal_buff1;
        end
    end

    assign signal_out = signal_buff2;
endmodule
