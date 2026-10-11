/**
 * 时钟分频模块
 */


/** 分频器
* clk: 输入时钟信号
* rst_n: 复位信号，低电平有效
* clk_div: 输出的分频时钟信号
* param NUM_DIV: 分频系数，必须为偶数，默认为10
*/
module clock_divider
#(
    parameter NUM_DIV = 10
)(
    input clk,
    input rst_n,
    output clk_div
);
    localparam MAX_CNT = NUM_DIV >> 1;
    localparam CNT_W = $clog2(MAX_CNT);

    reg r_clk_div;
    reg [CNT_W-1:0] count;
 
    always @(posedge clk or negedge rst_n)
    begin
        if (!rst_n)
        begin
            count <= '0;
            r_clk_div <= 1'b0;
        end
        else if (count < MAX_CNT - 1)
        begin
            count <= count + 1'b1;
        end
        else
        begin
            count <= '0;
            r_clk_div <= ~r_clk_div;
        end
    end

    assign clk_div = r_clk_div;
endmodule
