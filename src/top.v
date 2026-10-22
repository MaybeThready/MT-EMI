/**
 * 32 路相位累加器组时序测试顶层
 * 内部产生变化的频率和 note_on 事件，并汇总全部声部输出
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

    reg [15:0] test_count;
    reg [31:0] voice_select;
    always @(posedge clk_sys or negedge rst_sys_n)
    begin
        if (!rst_sys_n)
        begin
            test_count <= 16'd0;
            voice_select <= 32'd1;
        end
        else if (smp_tick_up)
        begin
            test_count <= test_count + 1'b1;
            voice_select <= {voice_select[30:0], voice_select[31]};
        end
    end

    wire [31:0] note_on = test_count[6:5] == 2'b01 ? voice_select : 32'd0;
    wire [15:0] init_phase = test_count ^ 16'h5a5a;
    wire [31:0] freq [31:0];
    wire [11:0] out_phase [31:0];

    genvar g;
    generate
        for (g = 0; g < 32; g = g + 1)
        begin
            localparam [15:0] FREQ_HZ = 16'd110 + g * 16'd7;
            assign freq[g] = {FREQ_HZ, test_count};
        end
    endgenerate

    wire in_ready;
    wire out_valid;
    phase_accumulator_group #(
        .ACCUMULATOR_NUM(32)
    ) pa_g_u (
        .clk_sys(clk_sys),
        .rst_n(rst_sys_n),
        .smp_tick_up(smp_tick_up),
        .note_on(note_on),
        .init_phase(init_phase),
        .freq(freq),
        .out_phase(out_phase),
        .out_ready(1'b1),
        .in_valid(1'b1),
        .out_valid(out_valid),
        .in_ready(in_ready)
    );

    reg [11:0] phase_xor;
    integer i;
    always @(*)
    begin
        phase_xor = 12'd0;
        for (i = 0; i < 32; i = i + 1)
            phase_xor = phase_xor ^ out_phase[i];
    end
    assign out = {1'b0, smp_tick_up, in_ready, out_valid, phase_xor};
endmodule
