/**
 * 波表合成模块：每个复音声部由一个基础振荡器和两路失谐振荡器组成。
 * 两路波表插值器分两批取得三个采样点，声部合成后只乘一次音量。
 */

/**
 * OSC_NUM: 复音声部数，不是振荡器总数。
 * phase[3*voice+osc]: UQ0.12；osc 顺序为基础、-12 音分、+12 音分。
 * volume[voice]: UQ0.16；wavetable_interp: UQ1.15。
 * audio_out: 32 声部时为 21 位 SQ6.15，接口及后续混音链不变。
 * K2=0 时只输出基础振荡器；最大失谐时使用 (8*基础+4*两路失谐之和)/16。
 * 中间位置按 detune 连续改变两路的混合权重，再乘音量并累加。
 * 输入和输出分别在 valid && ready 的时钟上升沿交付。
 */
module wavetable_synthesizer
#(
    parameter OSC_NUM = 32
)(
    input clk_sys,
    input rst_n,
    input smp_tick_up,
    input [11:0] phase [OSC_NUM*3-1:0],
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

    reg [11:0] phase_r [OSC_NUM*3-1:0];
    reg [15:0] volume_r [OSC_NUM-1:0];
    reg [15:0] volume_lane_r;
    reg [15:0] detune_r;
    reg [3:0] wavetable_0_r, wavetable_1_r;
    reg [15:0] wavetable_interp_r;
    reg [IDX_W-1:0] voice_index;
    reg batch_index;
    reg signed [15:0] sample_r [0:2];
    reg [32:0] blend_magnitude_r;
    reg blend_negative_r;
    reg signed [15:0] voice_point_r;
    reg signed [AUDIO_W-1:0] audio_sum_r;

    wire [IDX_W+1:0] voice_base = voice_index * 3;
    wire [11:0] interp_phase_0 = phase_r[voice_base + (batch_index ? 2 : 0)];
    wire [11:0] interp_phase_1 = phase_r[voice_base + 1];
    wire signed [15:0] sample_0, sample_1;
    wire [1:0] interp_ready, interp_valid;
    wire all_ready = interp_ready[0] && (batch_index || interp_ready[1]);
    wire all_valid = interp_valid[0] && (batch_index || interp_valid[1]);
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
        .sample_point(sample_1), .out_ready(accept_result && !batch_index),
        .in_valid(stc == SEND_INTERP && !batch_index),
        .out_valid(interp_valid[1]), .in_ready(interp_ready[1])
    );

    wire signed [17:0] side_delta =
        {{2{sample_r[1][15]}}, sample_r[1]} +
        {{2{sample_r[2][15]}}, sample_r[2]} -
        ({{2{sample_r[0][15]}}, sample_r[0]} <<< 1);
    // |side_delta| <= 131070；乘积保留 33 位，之后除以 4。
    wire [16:0] side_magnitude = side_delta[17] ? -side_delta : side_delta;
    wire [32:0] rounded_magnitude = blend_magnitude_r + 33'd131072;
    wire signed [17:0] partial_adjust = blend_negative_r ?
        -$signed({3'b000, rounded_magnitude[32:18]}) :
         $signed({3'b000, rounded_magnitude[32:18]});
    // UQ0.16 cannot encode 1.0; treat 0xffff as the exact 50/50 endpoint.
    wire [17:0] full_side_sum = {1'b0, side_magnitude} + 18'd2;
    wire [15:0] full_side_magnitude = full_side_sum >> 2;
    wire signed [17:0] full_adjust = blend_negative_r ?
        -$signed({2'b00, full_side_magnitude}) :
         $signed({2'b00, full_side_magnitude});
    wire signed [17:0] side_adjust = detune_r == 16'hffff ?
                                      full_adjust : partial_adjust;
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
            for (i = 0; i < OSC_NUM*3; i = i + 1)
                phase_r[i] <= '0;
            for (i = 0; i < OSC_NUM; i = i + 1)
                volume_r[i] <= '0;
            for (i = 0; i < 3; i = i + 1)
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
                        for (i = 0; i < OSC_NUM*3; i = i + 1)
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
                            sample_r[2] <= sample_0;
                        end
                        else
                        begin
                            sample_r[0] <= sample_0;
                            sample_r[1] <= sample_1;
                            batch_index <= 1'b1;
                        end
                    end
                end

                MIX:
                begin
                    blend_magnitude_r <= side_magnitude * detune_r;
                    blend_negative_r <= side_delta[17];
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
