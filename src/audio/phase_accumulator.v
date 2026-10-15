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

    localparam IDLE = 3'd0, RECEIVE = 3'd1, MULT = 3'd2, ADD = 3'd3, SEND = 3'd4;

    wire [2:0] stc;
    reg [2:0] stn;
    fsm #(
        .W(3),
        .INITIAL_STATE(IDLE)
    ) fsm_u (
        .clk(clk_sys),
        .rst_n(rst_n),
        .stn(stn),
        .stc(stc)
    );

    always @(*)
    begin
        case (stc)
            IDLE: stn = smp_tick_up ? RECEIVE : IDLE;
            RECEIVE: stn = in_valid ? (note_on ? SEND: MULT) : RECEIVE;  // note_on 触发后不需要累加直接去发送数据
            MULT: stn = ADD;  // 乘法占用一个周期
            ADD: stn = SEND;  // 加法占用一个周期
            SEND: stn = out_ready ? IDLE : SEND;
            default: stn = IDLE;
        endcase
    end

    reg out_valid_r;
    reg in_ready_r;
    reg [11:0] out_phase_r;
    
    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            freq_r <= '0;
            phase <= '0;
            out_phase_r <= '0;
            out_valid_r <= 1'b0;
            in_ready_r <= 1'b0;
        end
        else
        begin
            out_valid_r <= 1'b0;  // 默认值
            in_ready_r <= 1'b0;
            case (stc)
                IDLE:
                begin
                    in_ready_r <= 1'b1;
                end

                RECEIVE:
                begin
                    freq_r <= in_valid ? freq : freq_r;
                    phase <= in_valid & note_on ? {init_phase, {(PHASE_ACC_WIDTH - 16){1'b0}}} : phase;
                end

                ADD:
                begin
                    phase <= phase + phase_increment;
                end

                SEND:
                begin
                    out_phase_r <= out_phase_w;
                    out_valid_r <= 1'b1;
                end
            endcase
        end
    end

    assign out_phase = out_phase_r;
    assign out_valid = out_valid_r;
    assign in_ready = in_ready_r;
endmodule
