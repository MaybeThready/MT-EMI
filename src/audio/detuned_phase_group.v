/**
 * 三振荡器相位组。每声部为主音及约 +/-12 音分的两路失谐音。
 * 各声部三路相位依次更新，共用读取选择器与相位加法器。
 * detune 仅在后级 wavetable_synthesizer 中控制混合比例。
 */
`include "../defines.vh"

module detuned_phase_group
#(
    parameter VOICE_NUM = 32,
    parameter SMP_TICK_FREQ = `SMP_TICK_FREQ
)(
    input clk_sys,
    input rst_n,
    input smp_tick_up,
    input [VOICE_NUM-1:0] note_on,
    input [31:0] freq [VOICE_NUM-1:0],  // UQ16.16 Hz
    output [11:0] out_phase [VOICE_NUM*3-1:0],  // UQ0.12；主音、低失谐、高失谐
    input out_ready,
    input in_valid,
    output out_valid,
    output in_ready
);
    localparam IDX_W = VOICE_NUM > 1 ? $clog2(VOICE_NUM) : 1;
    localparam [31:0] PHASE_INCR_K = (64'd1 << 32) / SMP_TICK_FREQ;
    localparam [19:0] FIXED_RATIO_Q20 = 20'd7294;

    localparam WF_TICK = 4'd0, WF_RECV = 4'd1, CALC_BASE = 4'd2,
               CALC_OFFSET = 4'd3, SELECT_STEP = 4'd4, READ_PHASE = 4'd5,
               UPDATE_PHASE = 4'd6, NEXT_OSC = 4'd7,
               NEXT_VOICE = 4'd8, WF_SEND = 4'd9;
    wire [3:0] stc;
    reg [3:0] stn;
    fsm #(.W(4), .INITIAL_STATE(WF_TICK)) fsm_u (
        .clk(clk_sys), .rst_n(rst_n), .stn(stn), .stc(stc)
    );

    reg [31:0] freq_r [VOICE_NUM-1:0];
    reg [VOICE_NUM-1:0] note_on_r;
    reg [IDX_W-1:0] voice_index;
    reg [2:0] osc_index;
    reg [31:0] base_increment_r, offset_r;
    reg [31:0] step_r, selected_phase_r;
    reg [31:0] phase_r [VOICE_NUM*3-1:0];

    wire [63:0] base_product = freq_r[voice_index] * PHASE_INCR_K;
    wire [51:0] offset_product = base_increment_r * FIXED_RATIO_Q20;
    wire [IDX_W+1:0] current_index = voice_index * 3 + osc_index;
    wire [31:0] phase_next = selected_phase_r + step_r;

    genvar lane;
    generate
        for (lane = 0; lane < VOICE_NUM*3; lane = lane + 1)
        begin : phase_outputs
            unsigned_fp_norm #(
                .QII(0), .QIF(32), .QOI(0), .QOF(12)
            ) phase_norm_u (
                .in(phase_r[lane]), .out(out_phase[lane])
            );
        end
    endgenerate

    always @(*)
    begin
        case (stc)
            WF_TICK: stn = smp_tick_up ? WF_RECV : WF_TICK;
            WF_RECV: stn = in_valid ? CALC_BASE : WF_RECV;
            CALC_BASE: stn = CALC_OFFSET;
            CALC_OFFSET: stn = SELECT_STEP;
            SELECT_STEP: stn = READ_PHASE;
            READ_PHASE: stn = UPDATE_PHASE;
            UPDATE_PHASE: stn = NEXT_OSC;
            NEXT_OSC: stn = osc_index == 3'd2 ? NEXT_VOICE : SELECT_STEP;
            NEXT_VOICE: stn = voice_index == VOICE_NUM-1 ? WF_SEND : CALC_BASE;
            WF_SEND: stn = out_ready ? WF_TICK : WF_SEND;
            default: stn = WF_TICK;
        endcase
    end

    integer i;
    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            note_on_r <= '0;
            voice_index <= '0;
            osc_index <= '0;
            base_increment_r <= '0;
            offset_r <= '0;
            step_r <= '0;
            selected_phase_r <= '0;
            for (i = 0; i < VOICE_NUM; i = i + 1)
                freq_r[i] <= '0;
            for (i = 0; i < VOICE_NUM*3; i = i + 1)
                phase_r[i] <= '0;
        end
        else
        begin
            case (stc)
                WF_RECV:
                begin
                    if (in_valid)
                    begin
                        note_on_r <= note_on;
                        voice_index <= '0;
                        osc_index <= '0;
                        for (i = 0; i < VOICE_NUM; i = i + 1)
                            freq_r[i] <= freq[i];
                    end
                end
                CALC_BASE:
                    base_increment_r <= (base_product + 64'd32768) >> 16;
                CALC_OFFSET:
                    offset_r <= (offset_product + 52'd524288) >> 20;
                SELECT_STEP:
                    step_r <= osc_index == 3'd0 ? base_increment_r :
                              osc_index == 3'd1 ? base_increment_r - offset_r :
                                                  base_increment_r + offset_r;
                READ_PHASE:
                    selected_phase_r <= phase_r[current_index];
                UPDATE_PHASE:
                begin
                    for (i = 0; i < VOICE_NUM*3; i = i + 1)
                    begin
                        if (current_index == i)
                            phase_r[i] <= note_on_r[voice_index] ? 32'd0 : phase_next;
                    end
                end
                NEXT_OSC:
                begin
                    if (osc_index != 3'd2)
                        osc_index <= osc_index + 1'b1;
                end
                NEXT_VOICE:
                begin
                    if (voice_index != VOICE_NUM-1)
                    begin
                        voice_index <= voice_index + 1'b1;
                        osc_index <= '0;
                    end
                end
            endcase
        end
    end

    assign in_ready = stc == WF_RECV;
    assign out_valid = stc == WF_SEND;
endmodule
