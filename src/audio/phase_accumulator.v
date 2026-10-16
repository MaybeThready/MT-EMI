/**
 * 相位累加器模块
 * 接口定义与相位累加器组类似
 */

 `include "../defines.vh"

module phase_accumulator
#(
    parameter PHASE_ACC_WIDTH = 32,
    parameter SMP_TICK_FREQ = `SMP_TICK_FREQ
)(
    input clk_sys,
    input rst_n,
    input smp_tick_up,
    input note_on,
    input [15:0] init_phase,  // UQ0.16
    input [31:0] freq,  // UQ16.16
    output [11:0] out_phase,  // UQ0.12

    input out_ready,
    input in_valid,
    output out_valid,
    output in_ready
);
    localparam [PHASE_ACC_WIDTH-1:0] PHASE_INCR_K = (64'd1 << PHASE_ACC_WIDTH) / SMP_TICK_FREQ;  // UQ0.(PAW)

    reg [31:0] freq_r;
    wire [PHASE_ACC_WIDTH-1:0] phase_increment;
    unsigned_fp_mult #(
        .QII_A(0),
        .QIF_A(PHASE_ACC_WIDTH),
        .QII_B(16),
        .QIF_B(16),
        .QOI(0),
        .QOF(PHASE_ACC_WIDTH)
    ) ufm_u (
        .clk(clk_sys),
        .rst_n(rst_n),
        .in_a(PHASE_INCR_K),
        .in_b(freq_r),
        .out(phase_increment)
    );

    reg [PHASE_ACC_WIDTH-1:0] phase;
    wire [11:0] out_phase_w;
    unsigned_fp_norm #(
        .QII(0),
        .QIF(PHASE_ACC_WIDTH),
        .QOI(0),
        .QOF(12)
    ) ufn_u (
        .in(phase),
        .out(out_phase_w)
    );

    localparam WF_TICK = 3'd0, WF_RECV = 3'd1, MULT = 3'd2, ADD = 3'd3, ASSIGN = 3'd4, WF_SEND = 3'd5;  // WF 是WaitingFor的简称

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

    always @(*)
    begin
        case (stc)
            WF_TICK: stn = smp_tick_up ? WF_RECV : WF_TICK;
            WF_RECV: stn = in_valid ? (note_on ? ASSIGN: MULT) : WF_RECV;  // note_on 触发后不需要累加直接去发送数据
            MULT: stn = ADD;  // 乘法占用一个周期
            ADD: stn = ASSIGN;  // 加法占用一个周期
            ASSIGN: stn = WF_SEND;  // 非阻塞赋值占用一个周期
            WF_SEND: stn = out_ready ? WF_TICK : WF_SEND;
            default: stn = WF_TICK;
        endcase
    end

    reg [11:0] out_phase_r;
    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            freq_r <= '0;
            phase <= '0;
            out_phase_r <= '0;
        end
        else
        begin
            case (stc)
                WF_RECV:
                begin
                    freq_r <= in_valid ? freq : freq_r;
                    phase <= in_valid & note_on ? {init_phase, {(PHASE_ACC_WIDTH - 16){1'b0}}} : phase;
                end

                ADD:
                begin
                    phase <= phase + phase_increment;
                end

                ASSIGN:
                begin
                    out_phase_r <= out_phase_w;
                end
            endcase
        end
    end

    assign out_phase = out_phase_r;
    assign out_valid = (stc == WF_SEND);
    assign in_ready = (stc == WF_RECV);
endmodule
