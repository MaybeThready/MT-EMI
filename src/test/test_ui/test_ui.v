/**
 * UI 联合上板测试：键盘、八旋钮、四按键、UI、音频链、LCD 和音色存储。
 * 三个输入驱动各自完成 valid/ready 交付；以旋钮扫描帧为节拍，
 * 锁存最近的键盘与按键状态，组成一帧交给 UI。
 * 旋钮与键盘使用独立排针；四个外接按键高电平有效。
 * rst_n 保持既有测试的 K16 低有效复位引脚。
 */
module test_ui
#(
    parameter KEY_DEBOUNCE_TICKS = 200000,
    parameter BUTTON_DEBOUNCE_CYCLES = 98304,
    parameter KNOB_DEBOUNCE_TICKS = 98304,
    parameter WAVE_SELECT_STEPS = 4,
    parameter KNOB_TRANSITIONS_PER_STEP = 4,
    parameter [7:0] KNOB_DIRECTION_INVERT = 8'h00,
    parameter FLASH_HALF_PERIOD_CYCLES = 50,
    parameter FLASH_POWER_UP_CYCLES = 1000000
)( 
    input clk_core,
    input rst_n,
    input [3:0] ui_button,
    input data_a,
    input data_b,
    output load_n,
    output key_clk,
    input knob_serial_data,
    output knob_load_n,
    output knob_shift_clk,
    output i2s_bclk,
    output i2s_lrck,
    output i2s_dout,
    output sd_mode_n,
    output [5:0] status_led,
    output flash_cs_n, output flash_clk, output flash_mosi, input flash_miso,
    output flash_wp_n, output flash_hold_n,
    output lcd_clk, output lcd_en, output [5:0] lcd_r, output [5:0] lcd_g,
    output [5:0] lcd_b, output lcd_bl, output lcd_hs_n, output lcd_vs_n
);
    localparam MAX_POLYPHONY = 32;
    localparam KEY_NUM = 24;

    wire [15:0] ui_reverb_mix, mix_reverb_mix;
    wire [15:0] ui_reverb_make_up, mix_reverb_make_up;
    wire [15:0] ui_reverb_feedback, mix_reverb_feedback;
    wire [15:0] ui_reverb_damping, mix_reverb_damping;
    wire [15:0] ui_delay_mix, mix_delay_mix;
    wire [15:0] ui_delay_make_up, mix_delay_make_up;
    wire [15:0] ui_delay_time, mix_delay_time;
    wire [15:0] ui_delay_feedback, mix_delay_feedback;
    wire [15:0] ui_distortion_mix, mix_distortion_mix;
    wire [15:0] ui_distortion_make_up, mix_distortion_make_up;
    wire [15:0] ui_distortion_gain, mix_distortion_gain;
    wire [15:0] ui_distortion_tone, mix_distortion_tone;
    wire [15:0] ui_chorus_mix, mix_chorus_mix;
    wire [15:0] ui_chorus_make_up, mix_chorus_make_up;
    wire [15:0] ui_chorus_rate, mix_chorus_rate;
    wire [7:0] ui_chorus_depth, mix_chorus_depth;
    wire [15:0] ui_balance_volume, mix_balance_volume;
    wire [15:0] ui_master_volume, mix_master_volume;
    reg [279:0] mix_parameters_r;
    reg mix_parameters_busy_r;
    wire ui_audio_ready;
    wire [544:0] ui_display_state;
    wire ui_display_valid, ui_display_ready;
    wire lcd_protocol_error, lcd_configuration_error;
    wire signed [15:0] played_pcm;
    wire played_pcm_valid, played_pcm_ready;
    wire [3:0] button_states;
    wire button_valid, button_ready;
    wire [7:0] knob_states, knob_dirs, knob_pressed;
    wire knob_valid, knob_ready, knob_overflow, knob_scan_error;
    wire [2:0] menu_page;
    wire [1:0] menu_selection;
    wire storage_out_valid, storage_out_ready, storage_out_write;
    wire [3:0] storage_out_slot;
    wire [511:0] storage_out_data;
    wire storage_in_valid, storage_in_ready, storage_catalog_valid;
    wire [2:0] storage_in_status;
    wire [511:0] storage_in_data;
    wire [15:0] storage_slot_present;
    assign {mix_reverb_mix, mix_reverb_make_up, mix_reverb_feedback, mix_reverb_damping, mix_delay_mix, mix_delay_make_up, mix_delay_time, mix_delay_feedback, mix_distortion_mix, mix_distortion_make_up, mix_distortion_gain, mix_distortion_tone, mix_chorus_mix, mix_chorus_make_up, mix_chorus_rate, mix_chorus_depth, mix_balance_volume, mix_master_volume} = mix_parameters_r;
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
    wire keyboard_valid, keyboard_ready, ui_in_ready;
    keyboard_driver #(
        .KEY_NUM(KEY_NUM), .DEBOUNCE_TICKS(KEY_DEBOUNCE_TICKS),
        .PRESSURE_ENABLE(0)
    ) keyboard_driver_u (
        .clk_sys(clk_sys), .rst_n(rst_sys_n), .scan_tick_up(scan_tick_up),
        .data_a(data_a), .data_b(data_b),
        .out_ready(keyboard_ready), .load_n(load_n), .key_clk(key_clk),
        .key_states(key_states), .key_velocity(key_velocity),
        .out_valid(keyboard_valid),
        .mux_addr(), .mux_en_a_n(), .mux_en_b_n(),
        .adc_error(), .event_overflow(),
        .pressure_adc_req_valid(), .pressure_adc_req_ready(1'b0),
        .pressure_adc_result_valid(1'b0), .pressure_adc_result_ready(),
        .pressure_adc_result_code(14'd0), .pressure_adc_sample_error(1'b0),
        .pressure_adc_fault(1'b0)
    );

    knob_driver #(
        .KNOB_NUM(8), .TRANSITIONS_PER_STEP(KNOB_TRANSITIONS_PER_STEP),
        .DIRECTION_INVERT(KNOB_DIRECTION_INVERT),
        .DEBOUNCE_TICKS(KNOB_DEBOUNCE_TICKS)
    ) knob_driver_u (
        .clk_sys(clk_sys), .rst_n(rst_sys_n), .scan_tick_up(scan_tick_up),
        .serial_data(knob_serial_data), .out_ready(knob_ready),
        .load_n(knob_load_n), .shift_clk(knob_shift_clk),
        .knob_states(knob_states), .knob_dirs(knob_dirs),
        .knob_pressed(knob_pressed), .out_valid(knob_valid),
        .overflow(knob_overflow), .scan_error(knob_scan_error)
    );

    // 外接 B1～B4 按下为高，直接送入按键驱动。
    button_driver #(.DEBOUNCE_CYCLES(BUTTON_DEBOUNCE_CYCLES)) button_driver_u (
        .clk_sys(clk_sys), .rst_n(rst_sys_n), .scan_tick_up(scan_tick_up),
        .button_pins(ui_button), .out_ready(button_ready),
        .button_states(button_states), .out_valid(button_valid)
    );

    // 键盘与按键持续更新最新状态；旋钮帧（包含转动事件）不能被覆盖。
    // 接受旋钮帧时把另外两组状态一起冻结，UI 背压期间保持整帧不变。
    reg keyboard_seen_r, button_seen_r, knob_full_r;
    reg [KEY_NUM-1:0] key_latest_r;
    reg [15:0] velocity_latest_r [KEY_NUM-1:0];
    reg [3:0] button_latest_r;
    reg [KEY_NUM-1:0] key_frame_r;
    reg [15:0] velocity_frame_r [KEY_NUM-1:0];
    reg [7:0] knob_steps_r, knob_dirs_r, knob_pressed_r;
    reg [3:0] button_frame_r;
    wire combined_valid = knob_full_r;
    wire combined_fire = combined_valid && ui_in_ready;
    assign keyboard_ready = 1'b1;
    assign button_ready = 1'b1;
    assign knob_ready = !knob_full_r && keyboard_seen_r && button_seen_r;
    integer key_index;
    always @(posedge clk_sys or negedge rst_sys_n)
    begin
        if (!rst_sys_n)
        begin
            keyboard_seen_r <= 1'b0;
            button_seen_r <= 1'b0;
            knob_full_r <= 1'b0;
            key_latest_r <= '0;
            button_latest_r <= 4'd0;
            key_frame_r <= '0;
            knob_steps_r <= 8'd0;
            knob_dirs_r <= 8'd0;
            knob_pressed_r <= 8'd0;
            button_frame_r <= 4'd0;
            for (key_index = 0; key_index < KEY_NUM; key_index = key_index + 1)
            begin
                velocity_latest_r[key_index] <= 16'd0;
                velocity_frame_r[key_index] <= 16'd0;
            end
        end
        else
        begin
            if (combined_fire)
                knob_full_r <= 1'b0;
            if (keyboard_valid && keyboard_ready)
            begin
                keyboard_seen_r <= 1'b1;
                key_latest_r <= key_states;
                for (key_index = 0; key_index < KEY_NUM; key_index = key_index + 1)
                    velocity_latest_r[key_index] <= key_velocity[key_index];
            end
            if (knob_valid && knob_ready)
            begin
                knob_full_r <= 1'b1;
                key_frame_r <= key_latest_r;
                button_frame_r <= button_latest_r;
                for (key_index = 0; key_index < KEY_NUM; key_index = key_index + 1)
                    velocity_frame_r[key_index] <= velocity_latest_r[key_index];
                knob_steps_r <= knob_states;
                knob_dirs_r <= knob_dirs;
                knob_pressed_r <= knob_pressed;
            end
            if (button_valid && button_ready)
            begin
                button_seen_r <= 1'b1;
                button_latest_r <= button_states;
            end
        end
    end

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
    wire note_busy_valid, note_busy_ready;
    wire configuration_error, sample_overrun;
    wire [15:0] bend_value [0:0];
    assign bend_value[0] = 16'h8000;

    user_interface #(
        .KEY_NUM(KEY_NUM), .MAX_POLYPHONY(MAX_POLYPHONY),
        .CHANNEL_NUM(1), .WAVE_SELECT_STEPS(WAVE_SELECT_STEPS)
    ) user_interface_u (
        .clk_sys(clk_sys), .rst_n(rst_sys_n), .scan_tick_up(scan_tick_up),
        .key_states(key_frame_r), .key_velocity(velocity_frame_r),
        .knob_states(knob_steps_r), .knob_dirs(knob_dirs_r), .knob_pressed(knob_pressed_r),
        .bend_value(bend_value), .button_states(button_frame_r),
        .note_busy(note_busy), .note_busy_valid(note_busy_valid),
        .note_busy_ready(note_busy_ready), .note_on(note_on), .note_off(note_off),
        .note_freq(note_freq), .note_velocity(note_velocity),
        .wavetable_0(wavetable_0), .wavetable_1(wavetable_1),
        .wavetable_interp(wavetable_interp), .init_phase(init_phase),
        .attack_ticks(attack_ticks), .decay_ticks(decay_ticks),
        .sustain_level(sustain_level), .release_ticks(release_ticks),
        .smp_tick_up(smp_tick_up),
        .in_valid(combined_valid), .in_ready(ui_in_ready),
        .out_valid(ui_out_valid), .out_ready(ui_audio_ready),
        .master_volume(ui_master_volume), .reverb_mix(ui_reverb_mix), .delay_mix(ui_delay_mix),
        .distortion_mix(ui_distortion_mix), .chorus_mix(ui_chorus_mix),
        .reverb_make_up(ui_reverb_make_up), .delay_make_up(ui_delay_make_up),
        .distortion_make_up(ui_distortion_make_up), .chorus_make_up(ui_chorus_make_up),
        .reverb_feedback(ui_reverb_feedback), .reverb_damping(ui_reverb_damping), .delay_time(ui_delay_time), .delay_feedback(ui_delay_feedback), .distortion_gain(ui_distortion_gain), .distortion_tone(ui_distortion_tone), .chorus_rate(ui_chorus_rate), .chorus_depth(ui_chorus_depth), .balance_volume(ui_balance_volume),
        .display_out_state(ui_display_state), .display_out_valid(ui_display_valid), .display_out_ready(ui_display_ready),
        .menu_effect(), .menu_effect_reset(), .menu_advanced_parameters(),
        .configuration_error(configuration_error), .sample_overrun(sample_overrun),
        .storage_out_valid(storage_out_valid), .storage_out_ready(storage_out_ready),
        .storage_out_write(storage_out_write), .storage_out_slot(storage_out_slot), .storage_out_data(storage_out_data),
        .storage_in_valid(storage_in_valid), .storage_in_ready(storage_in_ready),
        .storage_in_status(storage_in_status), .storage_in_data(storage_in_data),
        .storage_catalog_valid(storage_catalog_valid), .storage_slot_present(storage_slot_present),
        .menu_page(menu_page), .menu_selection(menu_selection), .menu_slot(),
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
        .note_busy_valid(note_busy_valid), .note_busy_ready(note_busy_ready),
        .note_freq(note_freq), .note_velocity(note_velocity),
        .init_phase(init_phase[0]), .attack_ticks(attack_ticks[0]),
        .decay_ticks(decay_ticks[0]), .sustain_level(sustain_level[0]),
        .release_ticks(release_ticks[0]),
        .wavetable_0(wavetable_0[0]), .wavetable_1(wavetable_1[0]),
        .wavetable_interp(wavetable_interp[0]),
        .audio_out(rack_audio), .out_ready(rack_out_ready),
        .in_valid(ui_out_valid && !mix_parameters_busy_r), .out_valid(rack_out_valid), .in_ready(rack_in_ready)
    );

    wire signed [15:0] mixer_audio;
    wire mixer_in_ready, mixer_out_valid;
    wire i2s_ready;
    mixer #(
        .MAX_POLYPHONY(MAX_POLYPHONY)
    ) mixer_u (
        .clk_sys(clk_sys), .rst_n(rst_sys_n), .smp_tick_up(smp_tick_up),
        .audio_in(rack_audio),
        .reverb_mix(mix_reverb_mix), .reverb_make_up(mix_reverb_make_up), .reverb_feedback(mix_reverb_feedback),
        .reverb_damping(mix_reverb_damping),
        .delay_mix(mix_delay_mix), .delay_make_up(mix_delay_make_up), .delay_time(mix_delay_time),
        .delay_feedback(mix_delay_feedback),
        .distortion_mix(mix_distortion_mix), .distortion_make_up(mix_distortion_make_up), .distortion_gain(mix_distortion_gain),
        .distortion_tone(mix_distortion_tone),
        .chorus_mix(mix_chorus_mix), .chorus_make_up(mix_chorus_make_up), .chorus_rate(mix_chorus_rate),
        .chorus_depth(mix_chorus_depth),
        .balance_volume(mix_balance_volume), .master_volume(mix_master_volume),
        .audio_out(mixer_audio),
        .in_valid(rack_out_valid && mix_parameters_busy_r), .in_ready(mixer_in_ready),
        .out_valid(mixer_out_valid), .out_ready(i2s_ready)
    );

    reg output_started_r, sample_seen_r, underrun_r;
    reg [15:0] frame_count_r;
    wire sample_fire = mixer_out_valid && i2s_ready;
    assign rack_out_ready = mixer_in_ready && mix_parameters_busy_r;
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
        .audio_out_lcd(played_pcm), .out_valid_lcd(played_pcm_valid), .out_ready_lcd(played_pcm_ready),
        .i2s_bclk(i2s_bclk), .i2s_lrck(i2s_lrck),
        .i2s_dout(i2s_dout), .sd_mode_n(sd_mode_n)
    );
    // 板载 LED 低电平点亮：节拍、错误、菜单页、旋钮扫描故障。
    assign status_led[0] = ~frame_count_r[14];
    assign status_led[1] = ~(underrun_r | configuration_error | sample_overrun |
                             lcd_protocol_error | lcd_configuration_error);
    assign status_led[5] = ~(knob_overflow | knob_scan_error);

    // One in-flight rack transaction: bind mixer controls to the same UI
    // command, retaining them until rack->mixer accepts that sample.
    assign ui_audio_ready = rack_in_ready && !mix_parameters_busy_r;
    always @(posedge clk_sys or negedge rst_sys_n)
    begin
        if (!rst_sys_n)
        begin
            mix_parameters_r <= 280'd0;
            mix_parameters_busy_r <= 1'b0;
        end
        else
        begin
            if (rack_out_valid && rack_out_ready) mix_parameters_busy_r <= 1'b0;
            if (ui_out_valid && ui_audio_ready)
            begin
                mix_parameters_r <= {ui_reverb_mix, ui_reverb_make_up, ui_reverb_feedback, ui_reverb_damping, ui_delay_mix, ui_delay_make_up, ui_delay_time, ui_delay_feedback, ui_distortion_mix, ui_distortion_make_up, ui_distortion_gain, ui_distortion_tone, ui_chorus_mix, ui_chorus_make_up, ui_chorus_rate, ui_chorus_depth, ui_balance_volume, ui_master_volume};
                mix_parameters_busy_r <= 1'b1;
            end
        end
    end

    assign status_led[4:2] = ~menu_page;
    preset_storage_driver #(
        .HALF_PERIOD_CYCLES(FLASH_HALF_PERIOD_CYCLES), .POWER_UP_CYCLES(FLASH_POWER_UP_CYCLES)
    ) preset_storage_driver_u (
        .clk_sys(clk_sys), .rst_n(rst_sys_n),
        .in_valid(storage_out_valid), .in_ready(storage_out_ready), .in_write(storage_out_write),
        .in_slot(storage_out_slot), .in_data(storage_out_data),
        .out_valid(storage_in_valid), .out_ready(storage_in_ready),
        .out_status(storage_in_status), .out_data(storage_in_data),
        .catalog_valid(storage_catalog_valid), .slot_present(storage_slot_present), .jedec_id(),
        .flash_cs_n(flash_cs_n), .flash_clk(flash_clk), .flash_mosi(flash_mosi),
        .flash_miso(flash_miso), .flash_wp_n(flash_wp_n), .flash_hold_n(flash_hold_n)
    );

    // V3 LCD boundary: UI snapshot + actual-played I2S PCM; no demo source.
    lcd_display lcd_display_u (
        .clk_sys(clk_sys),.rst_n(rst_sys_n),
        .display_in_state(ui_display_state),.display_in_valid(ui_display_valid),.display_in_ready(ui_display_ready),
        .audio_in(played_pcm),.audio_in_valid(played_pcm_valid),.audio_in_ready(played_pcm_ready),
        .lcd_clk(lcd_clk),.lcd_en(lcd_en),.lcd_r(lcd_r),.lcd_g(lcd_g),.lcd_b(lcd_b),
        .lcd_bl(lcd_bl),.lcd_hs_n(lcd_hs_n),.lcd_vs_n(lcd_vs_n),
        .protocol_error(lcd_protocol_error),.configuration_error(lcd_configuration_error),.frame_active()
    );
endmodule
