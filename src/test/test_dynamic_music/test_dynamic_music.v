/**
 * 上板测试 3：32 声部机架循环演奏小星星乐句。
 * 每次只触发一个新声部，短暂的释放尾音可与下一个音重合。
 * 相邻音符改变正弦波与三角波的插值比例。
 */
module test_dynamic_music
(
    input clk_core,
    input rst_n,
    input data_a,
    input data_b,
    output load_n,
    output key_clk,
    output i2s_bclk,
    output i2s_lrck,
    output i2s_dout,
    output sd_mode_n,
    output [1:0] status_led
);
    localparam [13:0] STEP_SAMPLES = 14'd12_000;
    localparam [13:0] GATE_SAMPLES = 14'd10_000;
    localparam MAX_POLYPHONY = 32;

    wire clk_sys, rst_sys_n;
    wire i2s_tick_up, i2s_tick_down, smp_tick_up;
    sys_clocker sys_clocker_u (
        .clk_core(clk_core), .rst_n(rst_n),
        .clk_sys(clk_sys), .rst_sys_n(rst_sys_n)
    );
    sys_ticker sys_ticker_u (
        .clk_sys(clk_sys), .rst_n(rst_sys_n),
        .i2s_tick_up(i2s_tick_up), .i2s_tick_down(i2s_tick_down),
        .smp_tick_up(smp_tick_up), .smp_tick_down(),
        .scan_tick_up(), .scan_tick_down()
    );

    function [31:0] melody_freq;
        input [3:0] note_index;
        begin
            case (note_index)
                4'd0, 4'd1, 4'd13: melody_freq = 32'd17_145_893; // C4
                4'd2, 4'd3, 4'd6: melody_freq = 32'd25_689_813; // G4
                4'd4, 4'd5: melody_freq = 32'd28_835_840; // A4
                4'd7, 4'd8: melody_freq = 32'd22_887_021; // F4
                4'd9, 4'd10: melody_freq = 32'd21_602_472; // E4
                default: melody_freq = 32'd19_245_614; // D4
            endcase
        end
    endfunction

    reg [13:0] step_sample_r;
    reg [3:0] note_index_r;
    reg [31:0] voice_mask_r;
    wire [31:0] note_on = step_sample_r == 14'd0 ? voice_mask_r : 32'd0;
    wire [31:0] note_off = step_sample_r == GATE_SAMPLES ? voice_mask_r : 32'd0;
    wire [31:0] note_freq [MAX_POLYPHONY-1:0];
    wire [15:0] note_velocity [MAX_POLYPHONY-1:0];
    reg [31:0] note_freq_r [MAX_POLYPHONY-1:0];
    wire [31:0] note_busy;
    wire rack_in_ready, rack_out_valid, rack_out_ready;
    wire signed [20:0] rack_audio;

    genvar voice_index;
    generate
        for (voice_index = 0; voice_index < MAX_POLYPHONY; voice_index = voice_index + 1)
        begin : voice_inputs
            assign note_freq[voice_index] = note_on[voice_index] ?
                                            melody_freq(note_index_r) : note_freq_r[voice_index];
            assign note_velocity[voice_index] = 16'h7000;
        end
    endgenerate

    channel_rack #(
        .MAX_POLYPHONY(MAX_POLYPHONY)
    ) channel_rack_u (
        .clk_sys(clk_sys), .rst_n(rst_sys_n), .smp_tick_up(smp_tick_up),
        .note_on(note_on), .note_off(note_off), .note_busy(note_busy),
        .note_busy_valid(), .note_busy_ready(1'b1),
        .note_freq(note_freq), .note_velocity(note_velocity),
        .init_phase(16'd0), .attack_ticks(20'd240),
        .decay_ticks(20'd2400), .sustain_level(16'h9000),
        .release_ticks(20'd4800),
        .wavetable_0(4'd0), .wavetable_1(4'd1),
        .wavetable_interp({1'b0, note_index_r[2:0], 12'd0}),
        .audio_out(rack_audio), .out_ready(rack_out_ready),
        .in_valid(1'b1), .out_valid(rack_out_valid), .in_ready(rack_in_ready)
    );

    integer i;
    always @(posedge clk_sys or negedge rst_sys_n)
    begin
        if (!rst_sys_n)
        begin
            step_sample_r <= 14'd0;
            note_index_r <= 4'd0;
            voice_mask_r <= 32'd1;
            for (i = 0; i < MAX_POLYPHONY; i = i + 1)
                note_freq_r[i] <= 32'd0;
        end
        else if (rack_in_ready)
        begin
            for (i = 0; i < MAX_POLYPHONY; i = i + 1)
            begin
                if (note_on[i])
                    note_freq_r[i] <= melody_freq(note_index_r);
            end
            if (step_sample_r == STEP_SAMPLES - 1'b1)
            begin
                step_sample_r <= 14'd0;
                note_index_r <= note_index_r == 4'd13 ? 4'd0 : note_index_r + 1'b1;
                voice_mask_r <= {voice_mask_r[30:0], voice_mask_r[31]};
            end
            else
                step_sample_r <= step_sample_r + 1'b1;
        end
    end

    // 21 位混音结果只在超过 SQ1.15 范围时限幅，单音无需除以 32。
    wire signed [15:0] limited_audio =
        rack_audio[20:15] == {6{rack_audio[15]}} ? rack_audio[15:0] :
        (rack_audio[20] ? 16'sh8000 : 16'sh7fff);
    reg output_started_r, sample_seen_r, underrun_r;
    reg [15:0] frame_count_r;
    wire i2s_ready;
    wire sample_fire = rack_out_valid && i2s_ready;
    assign rack_out_ready = i2s_ready;
    always @(posedge clk_sys or negedge rst_sys_n)
    begin
        if (!rst_sys_n)
        begin
            output_started_r <= 1'b0;
            sample_seen_r <= 1'b0;
            underrun_r <= 1'b0;
            frame_count_r <= 16'd0;
        end
        else
        begin
            if (sample_fire)
                output_started_r <= 1'b1;
            if (smp_tick_up)
            begin
                frame_count_r <= frame_count_r + 1'b1;
                if (output_started_r && !sample_seen_r && !sample_fire)
                    underrun_r <= 1'b1;
                sample_seen_r <= sample_seen_r && sample_fire;
            end
            else if (sample_fire)
                sample_seen_r <= 1'b1;
        end
    end

    i2s_driver i2s_driver_u (
        .clk_sys(clk_sys), .rst_n(rst_sys_n),
        .i2s_tick_up(i2s_tick_up), .i2s_tick_down(i2s_tick_down),
        .smp_tick_up(smp_tick_up), .audio_data(limited_audio),
        .in_valid(rack_out_valid), .in_ready(i2s_ready),
        .audio_out_lcd(), .out_valid_lcd(), .out_ready_lcd(1'b1),
        .i2s_bclk(i2s_bclk), .i2s_lrck(i2s_lrck),
        .i2s_dout(i2s_dout), .sd_mode_n(sd_mode_n)
    );
    assign load_n = 1'b1;
    assign key_clk = 1'b0;
    assign status_led = {underrun_r, frame_count_r[14]};
endmodule
