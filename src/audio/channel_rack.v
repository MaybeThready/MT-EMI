/**
 * 单通道通道机架
 */

/**
 * MAX_POLYPHONY: 复音数量
 * note_freq: UQ16.16 音符频率
 * note_velocity: UQ0.16 音符力度
 * audio_out: 多路采样之和，SQ(1+$clog2(MAX_POLYPHONY)).15
 * note_busy/note_busy_valid/note_busy_ready: 交付给 UI 的整组声部状态快照，独立于音频输出握手。
 * 每个采样周期接收一次输入，等待相位和包络计算完成后生成一个采样点。
 * 输入和输出分别在 valid && ready 的时钟上升沿完成传输。
 */
module channel_rack
#(
    parameter MAX_POLYPHONY = 32
)(
    input clk_sys,
    input rst_n,
    input smp_tick_up,

    input [MAX_POLYPHONY-1:0] note_on,
    input [MAX_POLYPHONY-1:0] note_off,
    output [MAX_POLYPHONY-1:0] note_busy,
    output note_busy_valid,
    input note_busy_ready,

    input [31:0] note_freq [MAX_POLYPHONY-1:0],
    input [15:0] note_velocity [MAX_POLYPHONY-1:0],

    input [15:0] detune,  // UQ0.16；0 为无失谐，最大约 ±12 音分
    input [19:0] attack_ticks,
    input [19:0] decay_ticks,
    input [15:0] sustain_level,
    input [19:0] release_ticks,

    input [3:0] wavetable_0,
    input [3:0] wavetable_1,
    input [15:0] wavetable_interp,

    output signed [15+$clog2(MAX_POLYPHONY):0] audio_out,

    input out_ready,
    input in_valid,
    output out_valid,
    output in_ready
);
    localparam IDX_W = MAX_POLYPHONY > 1 ? $clog2(MAX_POLYPHONY) : 1;

    localparam WF_TICK = 4'd0, WF_RECV = 4'd1,
               WF_GROUP_SEND = 4'd2, MULT = 4'd3,
               GET_MULT = 4'd4, SEND_SYNTH = 4'd5,
               WF_SYNTH_SEND = 4'd6, WF_SEND = 4'd7,
               WF_SYNTH_READY = 4'd8, MULT_EXEC = 4'd9;

    wire [3:0] stc;
    reg [3:0] stn;
    fsm #(
        .W(4),
        .INITIAL_STATE(WF_TICK)
    ) fsm_u (
        .clk(clk_sys),
        .rst_n(rst_n),
        .stn(stn),
        .stc(stc)
    );

    wire [11:0] phase [MAX_POLYPHONY*5-1:0];
    wire [15:0] envelope_volume [MAX_POLYPHONY-1:0];
    wire [MAX_POLYPHONY-1:0] envelope_note_busy;
    reg [MAX_POLYPHONY-1:0] note_busy_r;
    reg note_busy_valid_r;
    reg [15:0] velocity_r [MAX_POLYPHONY-1:0];
    reg [15:0] volume_r [MAX_POLYPHONY-1:0];
    reg [15:0] volume_mult_a_r, volume_mult_b_r;
    reg [3:0] wavetable_0_r, wavetable_1_r;
    reg [15:0] wavetable_interp_r;
    reg [15:0] detune_r;
    reg [IDX_W-1:0] lane_index;

    wire phase_in_ready, envelope_in_ready;
    wire phase_out_valid, envelope_out_valid;
    wire synth_in_ready, synth_out_valid;
    // 两个组模块同时接收同一拍输入，也同时交给波表合成模块。
    wire group_in_valid = (stc == WF_RECV) && in_valid &&
                          phase_in_ready && envelope_in_ready && !note_busy_valid_r;
    wire synth_in_valid = (stc == SEND_SYNTH);
    wire group_out_ready = (stc == SEND_SYNTH);
    wire synth_out_ready = (stc == WF_SEND) && out_ready;

    detuned_phase_group #(
        .VOICE_NUM(MAX_POLYPHONY)
    ) phase_group_u (
        .clk_sys(clk_sys),
        .rst_n(rst_n),
        .smp_tick_up(smp_tick_up),
        .note_on(note_on),
        .detune(detune),
        .freq(note_freq),
        .out_phase(phase),
        .out_ready(group_out_ready),
        .in_valid(group_in_valid),
        .out_valid(phase_out_valid),
        .in_ready(phase_in_ready)
    );

    envelope_group #(
        .ENVELOPE_NUM(MAX_POLYPHONY)
    ) envelope_group_u (
        .clk_sys(clk_sys),
        .rst_n(rst_n),
        .smp_tick_up(smp_tick_up),
        .attack_ticks(attack_ticks),
        .decay_ticks(decay_ticks),
        .sustain_level(sustain_level),
        .release_ticks(release_ticks),
        .note_on(note_on),
        .note_off(note_off),
        .volume(envelope_volume),
        .note_busy(envelope_note_busy),
        .out_ready(group_out_ready),
        .in_valid(group_in_valid),
        .out_valid(envelope_out_valid),
        .in_ready(envelope_in_ready)
    );

    // 一份乘法器依次计算各声部的 包络音量 × 音符力度。
    // MULT 锁存当前声部操作数，MULT_EXEC 完成乘法，GET_MULT 收取结果。
    wire [15:0] volume_mult_result;
    unsigned_fp_mult #(
        .QII_A(0),
        .QIF_A(16),
        .QII_B(0),
        .QIF_B(16),
        .QOI(0),
        .QOF(16)
    ) volume_mult_u (
        .clk(clk_sys),
        .rst_n(rst_n),
        .in_a(volume_mult_a_r),
        .in_b(volume_mult_b_r),
        .out(volume_mult_result)
    );

    wire signed [15+$clog2(MAX_POLYPHONY):0] synth_audio_out;
    wavetable_synthesizer #(
        .OSC_NUM(MAX_POLYPHONY)
    ) synth_u (
        .clk_sys(clk_sys),
        .rst_n(rst_n),
        .smp_tick_up(smp_tick_up),
        .phase(phase),
        .volume(volume_r),
        .detune(detune_r),
        .wavetable_0(wavetable_0_r),
        .wavetable_1(wavetable_1_r),
        .wavetable_interp(wavetable_interp_r),
        .audio_out(synth_audio_out),
        .out_ready(synth_out_ready),
        .in_valid(synth_in_valid),
        .out_valid(synth_out_valid),
        .in_ready(synth_in_ready)
    );

    always @(*)
    begin
        case (stc)
            WF_TICK: stn = smp_tick_up ? WF_RECV : WF_TICK;
            WF_RECV: stn = group_in_valid ? WF_GROUP_SEND : WF_RECV;
            WF_GROUP_SEND: stn = (phase_out_valid && envelope_out_valid) ? MULT : WF_GROUP_SEND;
            MULT: stn = MULT_EXEC;
            MULT_EXEC: stn = GET_MULT;
            GET_MULT: stn = lane_index == MAX_POLYPHONY - 1 ? WF_SYNTH_READY : MULT;
            WF_SYNTH_READY: stn = (phase_out_valid && envelope_out_valid &&
                                   synth_in_ready) ? SEND_SYNTH : WF_SYNTH_READY;
            SEND_SYNTH: stn = WF_SYNTH_SEND;
            WF_SYNTH_SEND: stn = synth_out_valid ? WF_SEND : WF_SYNTH_SEND;
            WF_SEND: stn = (out_valid && out_ready) ? WF_TICK : WF_SEND;
            default: stn = WF_TICK;
        endcase
    end

    integer i;
    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            wavetable_0_r <= '0;
            wavetable_1_r <= '0;
            wavetable_interp_r <= '0;
            detune_r <= '0;
            lane_index <= '0;
            volume_mult_a_r <= '0;
            volume_mult_b_r <= '0;
            note_busy_r <= '0;
            note_busy_valid_r <= 1'b0;
            for (i = 0; i < MAX_POLYPHONY; i = i + 1)
            begin
                velocity_r[i] <= '0;
                volume_r[i] <= '0;
            end
        end
        else
        begin
            if (note_busy_valid_r && note_busy_ready)
                note_busy_valid_r <= 1'b0;
            if (stc == WF_GROUP_SEND && phase_out_valid && envelope_out_valid)
            begin
                note_busy_r <= envelope_note_busy;
                note_busy_valid_r <= 1'b1;
            end
            case (stc)
                WF_RECV:
                begin
                    if (group_in_valid)
                    begin
                        wavetable_0_r <= wavetable_0;
                        wavetable_1_r <= wavetable_1;
                        wavetable_interp_r <= wavetable_interp;
                        detune_r <= detune;
                        lane_index <= '0;
                        for (i = 0; i < MAX_POLYPHONY; i = i + 1)
                            velocity_r[i] <= note_velocity[i];
                    end
                end

                MULT:
                begin
                    volume_mult_a_r <= envelope_volume[lane_index];
                    volume_mult_b_r <= velocity_r[lane_index];
                end

                GET_MULT:
                begin
                    volume_r[lane_index] <= volume_mult_result;
                    if (lane_index != MAX_POLYPHONY - 1)
                        lane_index <= lane_index + 1'b1;
                end
            endcase
        end
    end

    assign audio_out = synth_audio_out;
    assign note_busy = note_busy_r;
    assign note_busy_valid = note_busy_valid_r;
    assign in_ready = (stc == WF_RECV) && phase_in_ready && envelope_in_ready && !note_busy_valid_r;
    assign out_valid = (stc == WF_SEND) && synth_out_valid;
endmodule
