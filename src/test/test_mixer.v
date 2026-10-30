/**
 * 上板测试 5：键盘、UI、32 声部机架、混音效果链和 I2S 级联。
 * 引脚与 test_keyboard_interaction 完全相同，可复用物理约束。
 * 只处理琴键按下、松开；效果与音量参数在下面集中设置。
 */
module test_mixer
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
    localparam MAX_POLYPHONY = 32;
    localparam KEY_NUM = 24;

    // 上板试听参数。修改这里并重新综合即可对比不同效果。
    // mix、feedback、damping、tone 均为 UQ0.16：16'h4000 约等于 0.25。
    localparam [15:0] REVERB_MIX = 16'h5000;       // 约 0.31
    localparam [15:0] REVERB_FEEDBACK = 16'ha000;  // 约 0.63
    localparam [15:0] REVERB_DAMPING = 16'h3000;   // 约 0.19
    localparam [15:0] DELAY_MIX = 16'h4000;        // 0.25
    localparam [15:0] DELAY_TIME = 16'd12000;      // 250 ms @ 48 kHz
    localparam [15:0] DELAY_FEEDBACK = 16'h6000;   // 约 0.38
    // localparam [15:0] DISTORTION_MIX = 16'h1800;   // 约 0.09
    localparam [15:0] DISTORTION_MIX = 16'h0000;
    localparam [15:0] DISTORTION_GAIN = 16'h2800;  // UQ4.12，2.5 倍
    localparam [15:0] DISTORTION_TONE = 16'hb000;  // 约 0.69
    // localparam [15:0] CHORUS_MIX = 16'h5000;       // 约 0.31
    localparam [15:0] CHORUS_MIX = 16'h0000;       // 约 0.31
    localparam [15:0] CHORUS_RATE = 16'h3000;      // UQ2.14，0.75 Hz
    localparam [7:0] CHORUS_DEPTH = 8'd48;         // 48 个采样，1 ms
    // 两级增益为 UQ1.15；mixer 末端还会固定除以 8。
    localparam [15:0] BALANCE_VOLUME = 16'h8000;  // 1.875 倍
    // localparam [15:0] MASTER_VOLUME = 16'hf000;   // 1.875 倍
    localparam [15:0] MASTER_VOLUME = 16'h8000;

    wire clk_sys, rst_sys_n;
    wire i2s_tick_up, i2s_tick_down, smp_tick_up, scan_tick_up;
    sys_clocker sys_clocker_u (
        .clk_core(clk_core), .rst_n(rst_n),
        .clk_sys(clk_sys), .rst_sys_n(rst_sys_n)
    );
    sys_ticker sys_ticker_u (
        .clk_sys(clk_sys), .rst_n(rst_sys_n),
        .i2s_tick_up(i2s_tick_up), .i2s_tick_down(i2s_tick_down),
        .smp_tick_up(smp_tick_up), .smp_tick_down(),
        .scan_tick_up(scan_tick_up), .scan_tick_down()
    );

    wire [KEY_NUM-1:0] key_states;
    wire [15:0] key_velocity [KEY_NUM-1:0];
    wire keyboard_valid, ui_in_ready;
    keyboard_driver #(
        .KEY_NUM(KEY_NUM)
    ) keyboard_driver_u (
        .clk_sys(clk_sys), .rst_n(rst_sys_n), .scan_tick_up(scan_tick_up),
        .data_a(data_a), .data_b(data_b),
        .out_ready(ui_in_ready), .load_n(load_n), .key_clk(key_clk),
        .key_states(key_states), .key_velocity(key_velocity),
        .out_valid(keyboard_valid)
    );

    wire [MAX_POLYPHONY-1:0] note_on, note_off, note_busy;
    wire [31:0] note_freq [MAX_POLYPHONY-1:0];
    wire [15:0] note_velocity [MAX_POLYPHONY-1:0];
    wire [3:0] wavetable_0 [0:0];
    wire [3:0] wavetable_1 [0:0];
    wire [15:0] wavetable_interp [0:0];
    wire [15:0] init_phase [0:0];
    wire [19:0] attack_ticks [0:0];
    wire [19:0] decay_ticks [0:0];
    wire [15:0] sustain_level [0:0];
    wire [19:0] release_ticks [0:0];
    wire ui_out_valid, rack_in_ready;
    wire configuration_error, sample_overrun;
    wire [15:0] bend_value [0:0];
    assign bend_value[0] = 16'h8000;

    user_interface #(
        .KEY_NUM(KEY_NUM), .MAX_POLYPHONY(MAX_POLYPHONY),
        .CHANNEL_NUM(1), .WAVE_SELECT_STEPS(4)
    ) user_interface_u (
        .clk_sys(clk_sys), .rst_n(rst_sys_n), .scan_tick_up(scan_tick_up),
        .key_states(key_states), .key_velocity(key_velocity),
        .knob_states(8'd0), .knob_dirs(8'd0), .knob_pressed(8'd0),
        .bend_value(bend_value), .button_states(4'd0),
        .note_busy(note_busy), .note_on(note_on), .note_off(note_off),
        .note_freq(note_freq), .note_velocity(note_velocity),
        .wavetable_0(wavetable_0), .wavetable_1(wavetable_1),
        .wavetable_interp(wavetable_interp), .init_phase(init_phase),
        .attack_ticks(attack_ticks), .decay_ticks(decay_ticks),
        .sustain_level(sustain_level), .release_ticks(release_ticks),
        .smp_tick_up(smp_tick_up),
        .in_valid(keyboard_valid), .in_ready(ui_in_ready),
        .out_valid(ui_out_valid), .out_ready(rack_in_ready),
        .master_volume(), .reverb_mix(), .delay_mix(),
        .distortion_mix(), .chorus_mix(),
        .configuration_error(configuration_error), .sample_overrun(sample_overrun),
        .storage_out_valid(), .storage_out_ready(1'b0),
        .storage_out_write(), .storage_out_slot(), .storage_out_data(),
        .storage_in_valid(1'b0), .storage_in_ready(),
        .storage_in_status(3'd0), .storage_in_data(512'd0),
        .storage_catalog_valid(1'b1), .storage_slot_present(16'd0),
        .menu_page(), .menu_selection(), .menu_slot(),
        .menu_save(), .menu_result_status(),
        .menu_slot_known(), .menu_slot_present()
    );

    wire signed [20:0] rack_audio;
    wire rack_out_valid, rack_out_ready;
    channel_rack #(
        .MAX_POLYPHONY(MAX_POLYPHONY)
    ) channel_rack_u (
        .clk_sys(clk_sys), .rst_n(rst_sys_n), .smp_tick_up(smp_tick_up),
        .note_on(note_on), .note_off(note_off), .note_busy(note_busy),
        .note_freq(note_freq), .note_velocity(note_velocity),
        .init_phase(init_phase[0]), .attack_ticks(attack_ticks[0]),
        .decay_ticks(decay_ticks[0]), .sustain_level(sustain_level[0]),
        .release_ticks(release_ticks[0]),
        .wavetable_0(wavetable_0[0]), .wavetable_1(wavetable_1[0]),
        .wavetable_interp(wavetable_interp[0]),
        .audio_out(rack_audio), .out_ready(rack_out_ready),
        .in_valid(ui_out_valid), .out_valid(rack_out_valid), .in_ready(rack_in_ready)
    );

    wire signed [15:0] mixer_audio;
    wire mixer_in_ready, mixer_out_valid;
    wire i2s_ready;
    mixer #(
        .MAX_POLYPHONY(MAX_POLYPHONY)
    ) mixer_u (
        .clk_sys(clk_sys), .rst_n(rst_sys_n), .smp_tick_up(smp_tick_up),
        .audio_in(rack_audio),
        .reverb_mix(REVERB_MIX), .reverb_feedback(REVERB_FEEDBACK),
        .reverb_damping(REVERB_DAMPING),
        .delay_mix(DELAY_MIX), .delay_time(DELAY_TIME),
        .delay_feedback(DELAY_FEEDBACK),
        .distortion_mix(DISTORTION_MIX), .distortion_gain(DISTORTION_GAIN),
        .distortion_tone(DISTORTION_TONE),
        .chorus_mix(CHORUS_MIX), .chorus_rate(CHORUS_RATE),
        .chorus_depth(CHORUS_DEPTH),
        .balance_volume(BALANCE_VOLUME), .master_volume(MASTER_VOLUME),
        .audio_out(mixer_audio),
        .in_valid(rack_out_valid), .in_ready(mixer_in_ready),
        .out_valid(mixer_out_valid), .out_ready(i2s_ready)
    );

    reg output_started_r, sample_seen_r, underrun_r;
    reg [15:0] frame_count_r;
    wire sample_fire = mixer_out_valid && i2s_ready;
    assign rack_out_ready = mixer_in_ready;
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
        .smp_tick_up(smp_tick_up), .audio_data(mixer_audio),
        .in_valid(mixer_out_valid), .in_ready(i2s_ready),
        .audio_out_lcd(), .out_valid_lcd(), .out_ready_lcd(1'b1),
        .i2s_bclk(i2s_bclk), .i2s_lrck(i2s_lrck),
        .i2s_dout(i2s_dout), .sd_mode_n(sd_mode_n)
    );
    assign status_led = {underrun_r | configuration_error | sample_overrun,
                         frame_count_r[14]};
endmodule
