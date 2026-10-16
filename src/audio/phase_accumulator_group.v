/**
 * 相位累加器组模块
 */

`include "../defines.vh"

/**
 * 相位累加器模块
 * 负责统筹管理多个相位累加器
 * ACCUMULATOR_NUM: 累加器个数
 * note_on：音符触发事件
 * init_phase: UQ0.16 初始相位
 * freq: UQ16.16 音符频率
 * out_phase: UQ0.12 输出相位
 */
module phase_accumulator_group
#(
    parameter PHASE_ACC_WIDTH = 32,
    parameter SMP_TICK_FREQ = `SMP_TICK_FREQ,
    parameter ACCUMULATOR_NUM = 32
)(
    input clk_sys,
    input rst_n,
    input smp_tick_up,
    input [ACCUMULATOR_NUM-1:0] note_on,
    input [15:0] init_phase,
    input [31:0] freq [ACCUMULATOR_NUM-1:0],
    output [11:0] out_phase [ACCUMULATOR_NUM-1:0],

    input out_ready,
    input in_valid,
    output out_valid,
    output in_ready
);
    wire out_ready_w;
    wire in_valid_w;
    wire [ACCUMULATOR_NUM-1:0] out_valids;
    wire [ACCUMULATOR_NUM-1:0] in_readys;
    genvar i;
    generate
        for (i = 0; i < ACCUMULATOR_NUM; i = i + 1)
        begin
            phase_accumulator #(
                .PHASE_ACC_WIDTH(PHASE_ACC_WIDTH),
                .SMP_TICK_FREQ(SMP_TICK_FREQ)
            ) pa_u (
                .clk_sys(clk_sys),
                .rst_n(rst_n),
                .smp_tick_up(smp_tick_up),
                .note_on(note_on[i]),
                .init_phase(init_phase),
                .freq(freq[i]),
                .out_phase(out_phase[i]),

                .out_ready(out_ready_w),
                .in_valid(in_valid_w),
                .out_valid(out_valids[i]),
                .in_ready(in_readys[i])
            );
        end
    endgenerate

    assign out_ready_w = out_ready & (&out_valids);
    assign in_valid_w = in_valid & (&in_readys);
    assign out_valid = &out_valids;
    assign in_ready = &in_readys;
endmodule
