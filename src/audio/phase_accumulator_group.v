/**
 * 相位累加器组模块
 */

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
endmodule
