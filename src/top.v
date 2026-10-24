/**
 * 波表合成器时序测试顶层
 * 用动态测试数据驱动全部声部，保留完整的插值、乘法与累加路径
 */

module top
(
    input clk_core,
    input rst_n,
    output [20:0] out
);
    localparam OSC_NUM = 32;

    wire clk_sys;
    wire rst_sys_n;
    sys_clocker sc_u (
        .clk_core(clk_core),
        .rst_n(rst_n),
        .clk_sys(clk_sys),
        .rst_sys_n(rst_sys_n)
    );

    wire smp_tick_up;
    sys_ticker st_u (
        .clk_sys(clk_sys),
        .rst_n(rst_sys_n),
        .i2s_tick_up(),
        .i2s_tick_down(),
        .smp_tick_up(smp_tick_up),
        .smp_tick_down(),
        .scan_tick_up(),
        .scan_tick_down()
    );

    reg [27:0] test_data [OSC_NUM-1:0];
    wire [11:0] phase [OSC_NUM-1:0];
    wire [15:0] volume [OSC_NUM-1:0];

    genvar g;
    generate
        for (g = 0; g < OSC_NUM; g = g + 1)
        begin
            assign phase[g] = test_data[g][11:0];
            assign volume[g] = test_data[g][27:12];
        end
    endgenerate

    integer i;
    always @(posedge clk_sys)
    begin
        if (!rst_sys_n)
        begin
            for (i = 0; i < OSC_NUM; i = i + 1)
                test_data[i] <= 28'h05a3c10 + i;
        end
        else if (smp_tick_up)
        begin
            for (i = 0; i < OSC_NUM; i = i + 1)
                test_data[i] <= {test_data[i][26:0],
                                 test_data[i][27] ^ test_data[i][24] ^
                                 test_data[i][22] ^ test_data[i][21]};
        end
    end

    wire signed [20:0] audio_out;
    wavetable_synthesizer #(
        .OSC_NUM(OSC_NUM)
    ) ws_u (
        .clk_sys(clk_sys),
        .rst_n(rst_sys_n),
        .smp_tick_up(smp_tick_up),
        .phase(phase),
        .volume(volume),
        .wavetable_0({2'b00, test_data[0][13:12]}),
        .wavetable_1({2'b00, test_data[1][13:12]}),
        .wavetable_interp({1'b0, test_data[2][26:12]}),
        .audio_out(audio_out),
        .out_ready(1'b1),
        .in_valid(1'b1),
        .out_valid(),
        .in_ready()
    );

    assign out = audio_out;
endmodule
