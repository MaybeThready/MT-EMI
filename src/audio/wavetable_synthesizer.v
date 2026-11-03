/**
 * 波表合成模块：每个复音声部由一个基础振荡器和四个失谐振荡器组成。
 * 三路波表插值器分两批取得五个采样点，声部合成后只乘一次音量。
 */

/**
 * OSC_NUM: 复音声部数，不是振荡器总数。
 * phase[5*voice+osc]: UQ0.12；osc 顺序为基础、-半、+半、-全、+全。
 * volume[voice]: UQ0.16；wavetable_interp: UQ1.15。
 * audio_out: 32 声部时为 21 位 SQ6.15，接口及后续混音链不变。
 * K2=0 时只输出基础振荡器；最大失谐时使用 (8*基础+2*四路失谐之和)/16。
 * 中间位置按 detune 连续改变四路的混合权重，再乘音量并累加。
 * 输入和输出分别在 valid && ready 的时钟上升沿交付。
 */
module wavetable_synthesizer
#(
    parameter OSC_NUM = 32
)(
    input clk_sys,
    input rst_n,
    input smp_tick_up,
    input [11:0] phase [OSC_NUM*5-1:0],
    input [15:0] volume [OSC_NUM-1:0],
    input [15:0] detune,  // UQ0.16；0 时严格退化为单振荡器
    input [3:0] wavetable_0,
    input [3:0] wavetable_1,
    input [15:0] wavetable_interp,
    output signed [15+$clog2(OSC_NUM):0] audio_out,
    input out_ready,
    input in_valid,
    output out_valid,
    output in_ready
);
    localparam IDX_W = OSC_NUM > 1 ? $clog2(OSC_NUM) : 1;
    localparam AUDIO_W = 16 + $clog2(OSC_NUM);

    localparam WF_TICK = 4'd0, WF_RECV = 4'd1,
               WF_INTERP_READY = 4'd2, SEND_INTERP = 4'd3,
               WF_INTERP_RESULT = 4'd4, MIX = 4'd5,
               NORMALIZE = 4'd6, MULT_EXEC = 4'd7,
               ACCUM = 4'd8, WF_SEND = 4'd9;

    wire [3:0] stc;
    reg [3:0] stn;
    fsm #(.W(4), .INITIAL_STATE(WF_TICK)) fsm_u (
        .clk(clk_sys), .rst_n(rst_n), .stn(stn), .stc(stc)
    );

    reg [11:0] phase_r [OSC_NUM*5-1:0];
    reg [15:0] volume_r [OSC_NUM-1:0];
    reg [15:0] volume_lane_r;
    reg [15:0] detune_r;
    reg [3:0] wavetable_0_r, wavetable_1_r;
    reg [15:0] wavetable_interp_r;
    reg [IDX_W-1:0] voice_index;
    reg batch_index;
    reg signed [15:0] sample_r [0:4];
    reg [33:0] blend_magnitude_r;
    reg blend_negative_r;
    reg signed [15:0] voice_point_r;
    reg signed [AUDIO_W-1:0] audio_sum_r;

    wire [IDX_W+2:0] voice_base = voice_index * 5;
    wire [11:0] interp_phase_0 = phase_r[voice_base + (batch_index ? 3 : 0)];
    wire [11:0] interp_phase_1 = phase_r[voice_base + (batch_index ? 4 : 1)];
    wire [11:0] interp_phase_2 = phase_r[voice_base + 2];
    wire signed [15:0] sample_0, sample_1, sample_2;
    wire [2:0] interp_ready, interp_valid;
    wire all_ready = interp_ready[0] && interp_ready[1] &&
                     (batch_index || interp_ready[2]);
    wire all_valid = interp_valid[0] && interp_valid[1] &&
                     (batch_index || interp_valid[2]);
    wire accept_result = stc == WF_INTERP_RESULT && all_valid;

    wavetable_interpolation interp_u0 (
        .clk_sys(clk_sys), .rst_n(rst_n),
        .wavetable_0(wavetable_0_r), .wavetable_1(wavetable_1_r),
        .wavetable_interp(wavetable_interp_r), .phase(interp_phase_0),
        .sample_point(sample_0), .out_ready(accept_result),
        .in_valid(stc == SEND_INTERP),
        .out_valid(interp_valid[0]), .in_ready(interp_ready[0])
    );
    wavetable_interpolation interp_u1 (
        .clk_sys(clk_sys), .rst_n(rst_n),
        .wavetable_0(wavetable_0_r), .wavetable_1(wavetable_1_r),
        .wavetable_interp(wavetable_interp_r), .phase(interp_phase_1),
        .sample_point(sample_1), .out_ready(accept_result),
        .in_valid(stc == SEND_INTERP),
        .out_valid(interp_valid[1]), .in_ready(interp_ready[1])
    );
    wavetable_interpolation interp_u2 (
        .clk_sys(clk_sys), .rst_n(rst_n),
        .wavetable_0(wavetable_0_r), .wavetable_1(wavetable_1_r),
        .wavetable_interp(wavetable_interp_r), .phase(interp_phase_2),
        .sample_point(sample_2), .out_ready(accept_result && !batch_index),
        .in_valid(stc == SEND_INTERP && !batch_index),
        .out_valid(interp_valid[2]), .in_ready(interp_ready[2])
    );

    wire signed [18:0] side_delta =
        {{3{sample_r[1][15]}}, sample_r[1]} +
        {{3{sample_r[2][15]}}, sample_r[2]} +
        {{3{sample_r[3][15]}}, sample_r[3]} +
        {{3{sample_r[4][15]}}, sample_r[4]} -
        ({{3{sample_r[0][15]}}, sample_r[0]} <<< 2);
    // |side_delta| <= 262140 fits 18 bits; magnitude product fits 34 bits.
    // The original signed rounding is exactly sign * ((magnitude + 2^18) >> 19).
    wire [17:0] side_magnitude = side_delta[18] ? -side_delta : side_delta;
    wire [33:0] rounded_magnitude = blend_magnitude_r + 34'd262144;
    wire signed [17:0] side_adjust = blend_negative_r ?
        -$signed({3'b000, rounded_magnitude[33:19]}) :
         $signed({3'b000, rounded_magnitude[33:19]});
    wire signed [17:0] combined_point =
        {{2{sample_r[0][15]}}, sample_r[0]} + side_adjust;
    wire signed [16:0] volume_coeff = $signed({1'b0, volume_lane_r});
    wire signed [15:0] voice_sample;
    signed_fp_mult #(
        .QII_A(1), .QIF_A(15), .QII_B(1), .QIF_B(16),
        .QOI(1), .QOF(15)
    ) mult_u (
        .clk(clk_sys), .rst_n(rst_n),
        .in_a(voice_point_r), .in_b(volume_coeff), .out(voice_sample)
    );

    always @(*)
    begin
        case (stc)
            WF_TICK: stn = smp_tick_up ? WF_RECV : WF_TICK;
            WF_RECV: stn = in_valid ? WF_INTERP_READY : WF_RECV;
            WF_INTERP_READY: stn = all_ready ? SEND_INTERP : WF_INTERP_READY;
            SEND_INTERP: stn = WF_INTERP_RESULT;
            WF_INTERP_RESULT: stn = all_valid ?
                (batch_index ? MIX : WF_INTERP_READY) : WF_INTERP_RESULT;
            MIX: stn = NORMALIZE;
            NORMALIZE: stn = MULT_EXEC;
            MULT_EXEC: stn = ACCUM;
            ACCUM: stn = voice_index == OSC_NUM-1 ? WF_SEND : WF_INTERP_READY;
            WF_SEND: stn = out_ready ? WF_TICK : WF_SEND;
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
            volume_lane_r <= '0;
            detune_r <= '0;
            voice_index <= '0;
            batch_index <= 1'b0;
            blend_magnitude_r <= '0;
            blend_negative_r <= 1'b0;
            voice_point_r <= '0;
            audio_sum_r <= '0;
            for (i = 0; i < OSC_NUM*5; i = i + 1)
                phase_r[i] <= '0;
            for (i = 0; i < OSC_NUM; i = i + 1)
                volume_r[i] <= '0;
            for (i = 0; i < 5; i = i + 1)
                sample_r[i] <= '0;
        end
        else
        begin
            case (stc)
                WF_RECV:
                begin
                    if (in_valid)
                    begin
                        wavetable_0_r <= wavetable_0;
                        wavetable_1_r <= wavetable_1;
                        wavetable_interp_r <= wavetable_interp;
                        detune_r <= detune;
                        voice_index <= '0;
                        batch_index <= 1'b0;
                        audio_sum_r <= '0;
                        for (i = 0; i < OSC_NUM*5; i = i + 1)
                            phase_r[i] <= phase[i];
                        for (i = 0; i < OSC_NUM; i = i + 1)
                            volume_r[i] <= volume[i];
                    end
                end

                WF_INTERP_RESULT:
                begin
                    if (all_valid)
                    begin
                        if (batch_index)
                        begin
                            sample_r[3] <= sample_0;
                            sample_r[4] <= sample_1;
                        end
                        else
                        begin
                            sample_r[0] <= sample_0;
                            sample_r[1] <= sample_1;
                            sample_r[2] <= sample_2;
                            batch_index <= 1'b1;
                        end
                    end
                end

                MIX:
                begin
                    blend_magnitude_r <= side_magnitude * detune_r;
                    blend_negative_r <= side_delta[18];
                    volume_lane_r <= volume_r[voice_index];
                end

                NORMALIZE: voice_point_r <= combined_point[15:0];

                ACCUM:
                begin
                    audio_sum_r <= audio_sum_r +
                                   {{(AUDIO_W-16){voice_sample[15]}}, voice_sample};
                    if (voice_index != OSC_NUM-1)
                    begin
                        voice_index <= voice_index + 1'b1;
                        batch_index <= 1'b0;
                    end
                end
            endcase
        end
    end

    assign audio_out = audio_sum_r;
    assign out_valid = stc == WF_SEND;
    assign in_ready = stc == WF_RECV;
endmodule
