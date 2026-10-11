/**
 * 状态机模块
 */


/** 有限状态机
 * clk: 时钟信号
 * rst_n: 复位信号，低电平有效
 * stn: 下一个状态输入
 * initial_state: 初始状态，复位时stc被设置为该值
 * stc: 当前状态
 * W: 状态机位宽
 */
module fsm
#(
    parameter W = 2,
    parameter INITIAL_STATE = 0
)
(
    input clk,
    input rst_n,
    input [W-1:0] stn,
    output [W-1:0] stc
);
    reg [W-1 : 0] stc_r;

    always @(posedge clk or negedge rst_n)
    begin
        if (!rst_n)
        begin
            stc_r <= INITIAL_STATE;
        end
        else
        begin
            stc_r <= stn;
        end
    end

    assign stc = stc_r;
endmodule
