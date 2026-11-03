/**
 * 五振荡器相位组：每个声部保留一个基础音及四个对称失谐音。
 * 共用频率与失谐乘法器，避免每个振荡器复制完整的频率运算电路。
 */

`include "../defines.vh"

/**
 * freq: 各声部 UQ16.16 Hz；detune: UQ0.16，0 对应不失谐。
 * 最大偏移约为基础频率的 0.6956%，即 12 音分；内侧偏移为其一半。
 * out_phase[5*voice + osc]: UQ0.12，osc 顺序为基础、-半、+半、-全、+全。
 * 每次输入握手后更新所有声部；note_on 所在采样点五个相位均从 0 开始。
 */
module detuned_phase_group
#(
    parameter VOICE_NUM = 32,
    parameter SMP_TICK_FREQ = `SMP_TICK_FREQ
)(
    input clk_sys,
    input rst_n,
    input smp_tick_up,
    input [VOICE_NUM-1:0] note_on,
    input [31:0] freq [VOICE_NUM-1:0],
    input [15:0] detune,
    output [11:0] out_phase [VOICE_NUM*5-1:0],
    input out_ready,
    input in_valid,
    output out_valid,
    output in_ready
);
    localparam IDX_W = VOICE_NUM > 1 ? $clog2(VOICE_NUM) : 1;
    localparam [31:0] PHASE_INCR_K = (64'd1 << 32) / SMP_TICK_FREQ;
    localparam [19:0] MAX_RATIO_Q20 = 20'd7294;  // 2^(12/1200)-1 ≈ 7294/2^20

    localparam WF_TICK = 3'd0, WF_RECV = 3'd1, CALC_RATIO = 3'd2,
               CALC_BASE = 3'd3, CALC_OFFSET = 3'd4,
               UPDATE_PHASE = 3'd5, NEXT_VOICE = 3'd6, WF_SEND = 3'd7;

    wire [2:0] stc;
    reg [2:0] stn;
    fsm #(.W(3), .INITIAL_STATE(WF_TICK)) fsm_u (
        .clk(clk_sys), .rst_n(rst_n), .stn(stn), .stc(stc)
    );

    reg [31:0] freq_r [VOICE_NUM-1:0];
    reg [VOICE_NUM-1:0] note_on_r;
    reg [15:0] detune_r;
    reg [19:0] ratio_r;
    reg [IDX_W-1:0] voice_index;
    reg [31:0] base_increment_r, offset_r;
    reg [31:0] phase_r [VOICE_NUM*5-1:0];

    wire [35:0] ratio_product = detune_r * MAX_RATIO_Q20;
    wire [63:0] base_product = freq_r[voice_index] * PHASE_INCR_K;
    wire [51:0] offset_product = base_increment_r * ratio_r;
    wire [31:0] half_offset = offset_r >> 1;

    function [11:0] phase_to_address;
        input [31:0] value;
        begin
            phase_to_address = value[31:20] == 12'hfff ? 12'hfff :
                               value[31:20] + value[19];
        end
    endfunction

    genvar lane;
    generate
        for (lane = 0; lane < VOICE_NUM*5; lane = lane + 1)
        begin
            assign out_phase[lane] = phase_to_address(phase_r[lane]);
        end
    endgenerate

    always @(*)
    begin
        case (stc)
            WF_TICK: stn = smp_tick_up ? WF_RECV : WF_TICK;
            WF_RECV: stn = in_valid ? CALC_RATIO : WF_RECV;
            CALC_RATIO: stn = CALC_BASE;
            CALC_BASE: stn = CALC_OFFSET;
            CALC_OFFSET: stn = UPDATE_PHASE;
            UPDATE_PHASE: stn = NEXT_VOICE;
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
            detune_r <= '0;
            ratio_r <= '0;
            voice_index <= '0;
            base_increment_r <= '0;
            offset_r <= '0;
            for (i = 0; i < VOICE_NUM; i = i + 1)
                freq_r[i] <= '0;
            for (i = 0; i < VOICE_NUM*5; i = i + 1)
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
                        detune_r <= detune;
                        voice_index <= '0;
                        for (i = 0; i < VOICE_NUM; i = i + 1)
                            freq_r[i] <= freq[i];
                    end
                end

                CALC_RATIO: ratio_r <= (ratio_product + 36'd32768) >> 16;
                CALC_BASE: base_increment_r <= (base_product + 64'd32768) >> 16;
                CALC_OFFSET: offset_r <= (offset_product + 52'd524288) >> 20;

                UPDATE_PHASE:
                begin
                    if (note_on_r[voice_index])
                    begin
                        phase_r[voice_index*5] <= '0;
                        phase_r[voice_index*5+1] <= '0;
                        phase_r[voice_index*5+2] <= '0;
                        phase_r[voice_index*5+3] <= '0;
                        phase_r[voice_index*5+4] <= '0;
                    end
                    else
                    begin
                        phase_r[voice_index*5] <= phase_r[voice_index*5] + base_increment_r;
                        phase_r[voice_index*5+1] <= phase_r[voice_index*5+1] + base_increment_r - half_offset;
                        phase_r[voice_index*5+2] <= phase_r[voice_index*5+2] + base_increment_r + half_offset;
                        phase_r[voice_index*5+3] <= phase_r[voice_index*5+3] + base_increment_r - offset_r;
                        phase_r[voice_index*5+4] <= phase_r[voice_index*5+4] + base_increment_r + offset_r;
                    end
                end

                NEXT_VOICE:
                begin
                    if (voice_index != VOICE_NUM-1)
                        voice_index <= voice_index + 1'b1;
                end
            endcase
        end
    end

    assign in_ready = stc == WF_RECV;
    assign out_valid = stc == WF_SEND;
endmodule
