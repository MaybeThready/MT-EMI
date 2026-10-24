/**
 * 波表合成模块
 */

/**
 * OSC_NUM: 振荡器个数
 * phase: UQ0.12 实时相位
 * volume: UQ0.16 音量
 * wavetable0/1: 波形插值端点。0正弦波，1三角波，2锯齿波，3方波
 * wavetable_interp: UQ1.15 [0,1]插值系数
 * audio_out: 单声道音频输出，SQ1.15
 */
module wavetable_synthesizer
#(
    parameter OSC_NUM = 32
)(
    input clk_sys,
    input rst_n,
    input smp_tick_up,
    input [11:0] phase [OSC_NUM-1:0],
    input [15:0] volume [OSC_NUM-1:0],
    input [3:0] wavetable_0,
    input [3:0] wavetable_1,
    input [15:0] wavetable_interp,
    output signed [15:0] audio_out,
    input out_ready,
    input in_valid,
    output out_valid,
    output in_ready
);
endmodule

