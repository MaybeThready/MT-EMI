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
    localparam WF_TICK = 3'd0, SEND_TICK = 3'd1, WF_SUB_RECV = 3'd2,
               WF_RECV = 3'd3, WF_SUB_SEND = 3'd4, WF_SEND = 3'd5;

    wire [2:0] stc;
    reg [2:0] stn;
    fsm #(
        .W(3),
        .INITIAL_STATE(WF_TICK)
    ) fsm_u (
        .clk(clk_sys),
        .rst_n(rst_n),
        .stn(stn),
        .stc(stc)
    );

    wire [ACCUMULATOR_NUM-1:0] out_valids;
    wire [ACCUMULATOR_NUM-1:0] in_readys;
    wire smp_tick_w = (stc == SEND_TICK);
    wire in_valid_w = (stc == WF_RECV) & in_valid;
    wire out_ready_w = (stc == WF_SEND) & out_ready;

    always @(*)
    begin
        case (stc)
            WF_TICK: stn = smp_tick_up ? SEND_TICK : WF_TICK;
            SEND_TICK: stn = WF_SUB_RECV;
            WF_SUB_RECV: stn = (&in_readys) ? WF_RECV : WF_SUB_RECV;
            WF_RECV: stn = in_valid ? WF_SUB_SEND : WF_RECV;
            WF_SUB_SEND: stn = (&out_valids) ? WF_SEND : WF_SUB_SEND;
            WF_SEND: stn = out_ready ? WF_TICK : WF_SEND;
            default: stn = WF_TICK;
        endcase
    end

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
                .smp_tick_up(smp_tick_w),
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

    assign in_ready = (stc == WF_RECV);
    assign out_valid = (stc == WF_SEND);
endmodule
