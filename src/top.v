/**
 * 包络组时序测试顶层
 * 内部产生变化的参数和按键事件，使 32 路包络都参与综合
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

    reg [19:0] test_count;
    reg [31:0] voice_select;
    always @(posedge clk_sys or negedge rst_sys_n)
    begin
        if (!rst_sys_n)
        begin
            test_count <= 20'd0;
            voice_select <= 32'd1;
        end
        else if (smp_tick_up)
        begin
            test_count <= test_count + 1'b1;
            voice_select <= {voice_select[30:0], voice_select[31]};
        end
    end

    wire [31:0] note_on = test_count[6:5] == 2'b01 ? voice_select : 32'd0;
    wire [31:0] note_off = test_count[6:5] == 2'b10 ? voice_select : 32'd0;
    wire [15:0] volume [31:0];
    wire [31:0] note_busy;
    wire out_valid;
    envelope_group #(
        .ENVELOPE_NUM(32)
    ) eg_u (
        .clk_sys(clk_sys),
        .rst_n(rst_sys_n),
        .smp_tick_up(smp_tick_up),
        .attack_ticks(test_count),
        .decay_ticks({test_count[9:0], test_count[19:10]}),
        .sustain_level(test_count[15:0]),
        .release_ticks(test_count ^ 20'h5a5a5),
        .note_on(note_on),
        .note_off(note_off),
        .volume(volume),
        .note_busy(note_busy),
        .out_ready(1'b1),
        .in_valid(1'b1),
        .out_valid(out_valid),
        .in_ready()
    );

    reg [15:0] volume_xor;
    integer i;
    always @(*)
    begin
        volume_xor = 16'd0;
        for (i = 0; i < 32; i = i + 1)
            volume_xor = volume_xor ^ volume[i];
    end
    assign out = volume_xor ^ {15'd0, (^note_busy) ^ out_valid};
endmodule
