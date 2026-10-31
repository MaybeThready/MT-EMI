/**
 * 硬削波失真。输入先乘增益，再限制到 SQ1.15 的 [-1, 1) 范围；
 * 一阶低通控制削波后高频含量，最后与原始 24 位采样干湿混合。
 * 三次乘法分时复用一个同步 signed_fp_mult，不占用音频 RAM。
 */

/**
 * clk_sys: 系统时钟；rst_n: 低有效异步复位
 * audio_in/audio_out: 24 位有符号 SQ9.15 效果器链采样
 * distortion_mix: 干湿比例，UQ0.16；0 为纯干声，16'hffff 近似纯湿声
 * distortion_gain: 削波前增益，UQ4.12；0 为静音，16'h1000 为 1 倍
 * distortion_tone: 亮度，UQ0.16；0 最暗，16'hffff 最亮
 * in_valid/in_ready、out_valid/out_ready: 每个采样各进行一次 valid-ready 握手
 * 每次输入握手后直到输出握手期间不接受下一输入；输出等待时保持稳定。
 * tone 滤波状态只在每个已接收采样处理时更新，包括纯干声模式。
 */
module distortion (
    input clk_sys,
    input rst_n,
    input signed [23:0] audio_in,
    input [15:0] distortion_mix,
    input [15:0] distortion_gain,
    input [15:0] distortion_tone,
    output signed [23:0] audio_out,
    input out_ready,
    input in_valid,
    output out_valid,
    output in_ready
);
    localparam WF_RECV = 4'd0, GAIN_SETUP = 4'd1,
               GAIN_MULT = 4'd2, GAIN_APPLY = 4'd3,
               TONE_SETUP = 4'd4, TONE_MULT = 4'd5,
               TONE_APPLY = 4'd6, MIX_SETUP = 4'd7,
               MIX_MULT = 4'd8, MIX_APPLY = 4'd9,
               WF_SEND = 4'd10, MIX_SUM = 4'd11;

    wire [3:0] stc;
    reg [3:0] stn;
    fsm #(
        .W(4),
        .INITIAL_STATE(WF_RECV)
    ) fsm_u (
        .clk(clk_sys),
        .rst_n(rst_n),
        .stn(stn),
        .stc(stc)
    );

    reg signed [23:0] audio_in_r, audio_out_r;
    reg signed [29:0] mix_scaled_r;
    reg signed [15:0] clipped_r, tone_state_r;
    reg [15:0] mix_r, gain_r, tone_r;

    // 1/256 <= alpha <= 65535/65536：小 tone 产生较强低通，
    // 大 tone 让削波的高频尽量通过；零值不会冻结滤波器。
    wire [16:0] tone_alpha_wide =
        {1'b0, tone_r} - {9'd0, tone_r[15:8]} + 17'd256;
    wire [15:0] tone_alpha = tone_alpha_wide[16] ?
                             16'hffff : tone_alpha_wide[15:0];

    // 增益 UQ4.12 左移四位后，与 tone/mix 共用 UQ4.16 乘数端口。
    reg signed [24:0] mult_a_r;
    reg signed [20:0] mult_b_r;
    wire signed [29:0] mult_scaled;
    signed_fp_mult #(
        .QII_A(10), .QIF_A(15),
        .QII_B(5), .QIF_B(16),
        .QOI(15), .QOF(15)
    ) mult_u (
        .clk(clk_sys), .rst_n(rst_n),
        .in_a(mult_a_r), .in_b(mult_b_r), .out(mult_scaled)
    );

    wire signed [15:0] gain_clipped;
    signed_fp_norm #(
        .QII(15), .QIF(15),
        .QOI(1), .QOF(15)
    ) gain_clip_u (
        .in(mult_scaled), .out(gain_clipped)
    );

    wire signed [16:0] tone_delta =
        $signed({clipped_r[15], clipped_r}) -
        $signed({tone_state_r[15], tone_state_r});
    wire signed [30:0] tone_sum =
        $signed({{15{tone_state_r[15]}}, tone_state_r}) +
        $signed({mult_scaled[29], mult_scaled});
    wire signed [15:0] tone_next;
    signed_fp_norm #(
        .QII(16), .QIF(15),
        .QOI(1), .QOF(15)
    ) tone_norm_u (
        .in(tone_sum), .out(tone_next)
    );

    wire signed [24:0] mix_delta =
        $signed({{9{tone_state_r[15]}}, tone_state_r}) -
        $signed({audio_in_r[23], audio_in_r});
    wire signed [30:0] mix_sum =
        $signed({{7{audio_in_r[23]}}, audio_in_r}) +
        $signed({mix_scaled_r[29], mix_scaled_r});
    wire signed [23:0] mix_result;
    signed_fp_norm #(
        .QII(16), .QIF(15),
        .QOI(9), .QOF(15)
    ) mix_norm_u (
        .in(mix_sum), .out(mix_result)
    );

    always @(*)
    begin
        case (stc)
            WF_RECV: stn = in_valid ? GAIN_SETUP : WF_RECV;
            GAIN_SETUP: stn = GAIN_MULT;
            GAIN_MULT: stn = GAIN_APPLY;
            GAIN_APPLY: stn = TONE_SETUP;
            TONE_SETUP: stn = TONE_MULT;
            TONE_MULT: stn = TONE_APPLY;
            TONE_APPLY: stn = MIX_SETUP;
            MIX_SETUP: stn = MIX_MULT;
            MIX_MULT: stn = MIX_APPLY;
            MIX_APPLY: stn = MIX_SUM;
            MIX_SUM: stn = WF_SEND;
            WF_SEND: stn = out_ready ? WF_RECV : WF_SEND;
            default: stn = WF_RECV;
        endcase
    end

    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            audio_in_r <= '0;
            audio_out_r <= '0;
            mix_scaled_r <= '0;
            clipped_r <= '0;
            tone_state_r <= '0;
            mix_r <= '0;
            gain_r <= '0;
            tone_r <= '0;
            mult_a_r <= '0;
            mult_b_r <= '0;
        end
        else
        begin
            case (stc)
                WF_RECV:
                begin
                    if (in_valid)
                    begin
                        audio_in_r <= audio_in;
                        mix_r <= distortion_mix;
                        gain_r <= distortion_gain;
                        tone_r <= distortion_tone;
                    end
                end

                GAIN_SETUP:
                begin
                    mult_a_r <= $signed({audio_in_r[23], audio_in_r});
                    mult_b_r <= $signed({1'b0, gain_r, 4'b0});
                end

                GAIN_APPLY: clipped_r <= gain_clipped;

                TONE_SETUP:
                begin
                    mult_a_r <= {{8{tone_delta[16]}}, tone_delta};
                    mult_b_r <= $signed({5'b0, tone_alpha});
                end

                TONE_APPLY: tone_state_r <= tone_next;

                MIX_SETUP:
                begin
                    mult_a_r <= mix_delta;
                    mult_b_r <= $signed({5'b0, mix_r});
                end

                MIX_APPLY: mix_scaled_r <= mult_scaled;

                MIX_SUM: audio_out_r <= mix_result;
            endcase
        end
    end

    assign audio_out = audio_out_r;
    assign out_valid = (stc == WF_SEND);
    assign in_ready = (stc == WF_RECV);
endmodule
