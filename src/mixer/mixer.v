/**
 * 混音效果器链。每次接收 channel_rack 的一个复音采样，依次执行
 * 失真、合唱、延迟、混响，再进行两级音量控制和 16 位 PCM 限幅。
 * 合唱、延迟、混响分时独占同一颗 audio_mix_buffer SDP RAM。
 * LCD 应从 I2S 已接收的 PCM 采样另行捕获，本模块不等待 LCD。
 */

/**
 * clk_sys: 系统时钟；rst_n: 低有效异步复位
 * smp_tick_up: 采样帧参考脉冲；实际采样由 in_valid && in_ready 接收
 * audio_in: 复音和，SQ(1+$clog2(MAX_POLYPHONY)).15
 * balance_volume/master_volume: UQ1.15，[0, 2)
 * audio_out: 单声道 16 位 SQ1.15 PCM，out_valid && out_ready 时交给 I2S
 * 效果器链内部及共享 RAM：24 位 SQ9.15；最终固定除以 8 并饱和。
 * 输出背压期间保持 audio_out、out_valid 稳定，不接收新输入。
 */
module mixer #(
    parameter MAX_POLYPHONY = 32
)(
    input clk_sys,
    input rst_n,
    input smp_tick_up,
    input signed [15+$clog2(MAX_POLYPHONY):0] audio_in,

    input [15:0] reverb_mix,
    input [15:0] reverb_feedback,
    input [15:0] reverb_damping,
    input [15:0] delay_mix,
    input [15:0] delay_time,
    input [15:0] delay_feedback,
    input [15:0] distortion_mix,
    input [15:0] distortion_gain,
    input [15:0] distortion_tone,
    input [15:0] chorus_mix,
    input [15:0] chorus_rate,
    input [7:0] chorus_depth,
    input [15:0] balance_volume,
    input [15:0] master_volume,

    output signed [15:0] audio_out,
    input out_ready,
    input in_valid,
    output out_valid,
    output in_ready
);
    localparam INPUT_W = 16 + $clog2(MAX_POLYPHONY);

    localparam WF_RECV = 5'd0,
               SEND_DIST = 5'd1, WAIT_DIST = 5'd2,
               SEND_CHORUS = 5'd3, WAIT_CHORUS = 5'd4,
               SEND_DELAY = 5'd5, WAIT_DELAY = 5'd6,
               SEND_REVERB = 5'd7, WAIT_REVERB = 5'd8,
               BALANCE_SETUP = 5'd9, BALANCE_MULT = 5'd10,
               BALANCE_APPLY = 5'd11, MASTER_SETUP = 5'd12,
               MASTER_MULT = 5'd13, MASTER_APPLY = 5'd14,
               WF_SEND = 5'd15;

    wire [4:0] stc;
    reg [4:0] stn;
    fsm #(.W(5), .INITIAL_STATE(WF_RECV)) fsm_u (
        .clk(clk_sys), .rst_n(rst_n), .stn(stn), .stc(stc)
    );

    wire signed [23:0] input_24;
    signed_fp_norm #(
        .QII(INPUT_W - 15), .QIF(15), .QOI(9), .QOF(15)
    ) input_norm_u (.in(audio_in), .out(input_24));

    reg signed [23:0] sample_r;
    reg [15:0] balance_r, master_r;
    reg [15:0] reverb_mix_r, reverb_feedback_r, reverb_damping_r;
    reg [15:0] delay_mix_r, delay_time_r, delay_feedback_r;
    reg [15:0] distortion_mix_r, distortion_gain_r, distortion_tone_r;
    reg [15:0] chorus_mix_r, chorus_rate_r;
    reg [7:0] chorus_depth_r;
    reg signed [15:0] audio_out_r;
    wire signed [23:0] dist_audio, chorus_audio, delay_audio, reverb_audio;
    wire dist_ready, dist_valid, chorus_ready, chorus_valid;
    wire delay_ready, delay_valid, reverb_ready, reverb_valid;
    wire chorus_read_en, chorus_write_en;
    wire delay_read_en, delay_write_en;
    wire reverb_read_en, reverb_write_en;
    wire [16:0] chorus_read_addr, chorus_write_addr;
    wire [16:0] delay_read_addr, delay_write_addr;
    wire [16:0] reverb_read_addr, reverb_write_addr;
    wire signed [23:0] chorus_write_data, delay_write_data, reverb_write_data;
    wire signed [23:0] ram_read_data;
    reg ram_read_en, ram_write_en;
    reg [16:0] ram_read_addr, ram_write_addr;
    reg signed [23:0] ram_write_data;

    distortion distortion_u (
        .clk_sys(clk_sys), .rst_n(rst_n), .audio_in(sample_r),
        .distortion_mix(distortion_mix_r), .distortion_gain(distortion_gain_r),
        .distortion_tone(distortion_tone_r), .audio_out(dist_audio),
        .in_valid(stc == SEND_DIST), .in_ready(dist_ready),
        .out_valid(dist_valid), .out_ready(stc == WAIT_DIST)
    );

    chorus chorus_u (
        .clk_sys(clk_sys), .rst_n(rst_n), .audio_in(sample_r),
        .chorus_mix(chorus_mix_r), .chorus_rate(chorus_rate_r),
        .chorus_depth(chorus_depth_r), .audio_out(chorus_audio),
        .in_valid(stc == SEND_CHORUS), .in_ready(chorus_ready),
        .out_valid(chorus_valid), .out_ready(stc == WAIT_CHORUS),
        .ram_read_en(chorus_read_en), .ram_read_addr(chorus_read_addr),
        .ram_read_data(ram_read_data),
        .ram_write_en(chorus_write_en), .ram_write_addr(chorus_write_addr),
        .ram_write_data(chorus_write_data)
    );

    delay delay_u (
        .clk_sys(clk_sys), .rst_n(rst_n), .audio_in(sample_r),
        .delay_mix(delay_mix_r), .delay_time(delay_time_r),
        .delay_feedback(delay_feedback_r), .audio_out(delay_audio),
        .in_valid(stc == SEND_DELAY), .in_ready(delay_ready),
        .out_valid(delay_valid), .out_ready(stc == WAIT_DELAY),
        .ram_read_en(delay_read_en), .ram_read_addr(delay_read_addr),
        .ram_read_data(ram_read_data),
        .ram_write_en(delay_write_en), .ram_write_addr(delay_write_addr),
        .ram_write_data(delay_write_data)
    );

    reverb #(
        .MAX_POLYPHONY(32), .AUDIO_IN_W(24)
    ) reverb_u (
        .clk_sys(clk_sys), .rst_n(rst_n), .audio_in(sample_r),
        .reverb_mix(reverb_mix_r), .reverb_feedback(reverb_feedback_r),
        .reverb_damping(reverb_damping_r), .audio_out(reverb_audio),
        .in_valid(stc == SEND_REVERB), .in_ready(reverb_ready),
        .out_valid(reverb_valid), .out_ready(stc == WAIT_REVERB),
        .ram_read_en(reverb_read_en), .ram_read_addr(reverb_read_addr),
        .ram_read_data(ram_read_data),
        .ram_write_en(reverb_write_en), .ram_write_addr(reverb_write_addr),
        .ram_write_data(reverb_write_data)
    );

    always @(*)
    begin
        ram_read_en = 1'b0;
        ram_write_en = 1'b0;
        ram_read_addr = 17'd0;
        ram_write_addr = 17'd0;
        ram_write_data = 24'sd0;
        case (stc)
            SEND_CHORUS, WAIT_CHORUS:
            begin
                ram_read_en = chorus_read_en;
                ram_write_en = chorus_write_en;
                ram_read_addr = chorus_read_addr;
                ram_write_addr = chorus_write_addr;
                ram_write_data = chorus_write_data;
            end
            SEND_DELAY, WAIT_DELAY:
            begin
                ram_read_en = delay_read_en;
                ram_write_en = delay_write_en;
                ram_read_addr = delay_read_addr;
                ram_write_addr = delay_write_addr;
                ram_write_data = delay_write_data;
            end
            SEND_REVERB, WAIT_REVERB:
            begin
                ram_read_en = reverb_read_en;
                ram_write_en = reverb_write_en;
                ram_read_addr = reverb_read_addr;
                ram_write_addr = reverb_write_addr;
                ram_write_data = reverb_write_data;
            end
        endcase
    end

    audio_mix_buffer ram_u (
        .dout(ram_read_data),
        .clka(clk_sys), .cea(ram_write_en), .ada(ram_write_addr),
        .din(ram_write_data),
        .clkb(clk_sys), .ceb(ram_read_en), .adb(ram_read_addr),
        .oce(1'b1), .reset(~rst_n)
    );

    // 复用一份同步乘法器。余额级结果存 26 位，主音量级结果存 27 位。
    reg signed [25:0] mult_a_r;
    reg signed [16:0] mult_b_r;
    wire signed [26:0] mult_result;
    signed_fp_mult #(
        .QII_A(11), .QIF_A(15),
        .QII_B(2), .QIF_B(15),
        .QOI(12), .QOF(15)
    ) gain_mult_u (
        .clk(clk_sys), .rst_n(rst_n),
        .in_a(mult_a_r), .in_b(mult_b_r), .out(mult_result)
    );
    wire signed [26:0] scaled_pcm = mult_result >>> 3;
    wire signed [15:0] saturated_pcm;
    signed_fp_norm #(
        .QII(12), .QIF(15), .QOI(1), .QOF(15)
    ) pcm_norm_u (.in(scaled_pcm), .out(saturated_pcm));

    always @(*)
    begin
        case (stc)
            WF_RECV: stn = in_valid ? SEND_DIST : WF_RECV;
            SEND_DIST: stn = dist_ready ? WAIT_DIST : SEND_DIST;
            WAIT_DIST: stn = dist_valid ? SEND_CHORUS : WAIT_DIST;
            SEND_CHORUS: stn = chorus_ready ? WAIT_CHORUS : SEND_CHORUS;
            WAIT_CHORUS: stn = chorus_valid ? SEND_DELAY : WAIT_CHORUS;
            SEND_DELAY: stn = delay_ready ? WAIT_DELAY : SEND_DELAY;
            WAIT_DELAY: stn = delay_valid ? SEND_REVERB : WAIT_DELAY;
            SEND_REVERB: stn = reverb_ready ? WAIT_REVERB : SEND_REVERB;
            WAIT_REVERB: stn = reverb_valid ? BALANCE_SETUP : WAIT_REVERB;
            BALANCE_SETUP: stn = BALANCE_MULT;
            BALANCE_MULT: stn = BALANCE_APPLY;
            BALANCE_APPLY: stn = MASTER_SETUP;
            MASTER_SETUP: stn = MASTER_MULT;
            MASTER_MULT: stn = MASTER_APPLY;
            MASTER_APPLY: stn = WF_SEND;
            WF_SEND: stn = out_ready ? WF_RECV : WF_SEND;
            default: stn = WF_RECV;
        endcase
    end

    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            sample_r <= '0;
            balance_r <= '0;
            master_r <= '0;
            reverb_mix_r <= '0;
            reverb_feedback_r <= '0;
            reverb_damping_r <= '0;
            delay_mix_r <= '0;
            delay_time_r <= '0;
            delay_feedback_r <= '0;
            distortion_mix_r <= '0;
            distortion_gain_r <= '0;
            distortion_tone_r <= '0;
            chorus_mix_r <= '0;
            chorus_rate_r <= '0;
            chorus_depth_r <= '0;
            audio_out_r <= '0;
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
                        sample_r <= input_24;
                        balance_r <= balance_volume;
                        master_r <= master_volume;
                        reverb_mix_r <= reverb_mix;
                        reverb_feedback_r <= reverb_feedback;
                        reverb_damping_r <= reverb_damping;
                        delay_mix_r <= delay_mix;
                        delay_time_r <= delay_time;
                        delay_feedback_r <= delay_feedback;
                        distortion_mix_r <= distortion_mix;
                        distortion_gain_r <= distortion_gain;
                        distortion_tone_r <= distortion_tone;
                        chorus_mix_r <= chorus_mix;
                        chorus_rate_r <= chorus_rate;
                        chorus_depth_r <= chorus_depth;
                    end
                end
                WAIT_DIST: if (dist_valid) sample_r <= dist_audio;
                WAIT_CHORUS: if (chorus_valid) sample_r <= chorus_audio;
                WAIT_DELAY: if (delay_valid) sample_r <= delay_audio;
                WAIT_REVERB: if (reverb_valid) sample_r <= reverb_audio;
                BALANCE_SETUP:
                begin
                    mult_a_r <= {{2{sample_r[23]}}, sample_r};
                    mult_b_r <= {1'b0, balance_r};
                end
                BALANCE_APPLY: mult_a_r <= mult_result[25:0];
                MASTER_SETUP: mult_b_r <= {1'b0, master_r};
                MASTER_APPLY: audio_out_r <= saturated_pcm;
            endcase
        end
    end

    assign audio_out = audio_out_r;
    assign out_valid = (stc == WF_SEND);
    assign in_ready = (stc == WF_RECV);
endmodule
