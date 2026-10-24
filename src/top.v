/**
 * 波表 ROM 时序测试顶层
 * 在系统时钟下循环读取全部地址，并将读数送至输出寄存器
 */

module top
(
    input clk_core,
    input rst_n,
    output [15:0] out
);
    wire clk_sys;
    wire rst_sys_n;
    sys_clocker sc_u
    (
        .clk_core(clk_core),
        .rst_n(rst_n),
        .clk_sys(clk_sys),
        .rst_sys_n(rst_sys_n)
    );

    reg [13:0] rom_addr;
    wire [15:0] rom_data;
    reg [15:0] out_r;

    always @(posedge clk_sys)
    begin
        if (!rst_sys_n)
        begin
            rom_addr <= 14'd0;
            out_r <= 16'd0;
        end
        else
        begin
            rom_addr <= rom_addr + 1'b1;
            out_r <= rom_data;
        end
    end

    rom_wavetables rom_u
    (
        .dout(rom_data),
        .clk(clk_sys),
        .oce(1'b1),
        .ce(1'b1),
        .reset(1'b0),
        .ad(rom_addr)
    );

    assign out = out_r;
endmodule
