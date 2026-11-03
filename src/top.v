/**
 * 正式整机顶层：24键及力度、弯音轮、八旋钮、四按键、32声部音频、
 * 效果器、I2S、LCD和音色Flash。所有业务时序均使用clk_sys。
 * K16低有效复位；四个外接UI按键高电平有效；旋钮物理K1..K8反接为UI K8..K1。
 * 压力ADCV和弯音ADCT通过一个shared_adc_manager分时使用ADCLRC。
 */
module top
#(
    parameter KEY_DEBOUNCE_TICKS = 98304,
    parameter BUTTON_DEBOUNCE_CYCLES = 98304,
    parameter KNOB_DEBOUNCE_TICKS = 98304,
    parameter WAVE_SELECT_STEPS = 4,
    parameter KNOB_TRANSITIONS_PER_STEP = 4,
    // 位号仍按物理旋钮编号；到UI的三组数据统一在驱动后反序。
    parameter [7:0] KNOB_DIRECTION_INVERT = 8'h00,
    parameter [335:0] PRESSURE_ZERO_CODES = {24{14'd0}},
    parameter [335:0] PRESSURE_FULL_CODES = {24{14'd1690}},
    parameter PRESSURE_DEADBAND_CODE = 8,
    parameter ADC_STARTUP_TICKS = 98304,
    parameter MUX_SETTLE_TICKS = 4916,
    parameter SHARED_SETTLE_TICKS = 4916,
    parameter BEND_SETTLE_TICKS = 4916,
    parameter BEND_DEBOUNCE_TICKS = 98304,
    parameter BEND_FILTER_SHIFT = 2,
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
    output [3:0] mux_addr,
    output mux_en_a_n,
    output mux_en_b_n,
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
    wire [279:0] ui_parameters, mix_parameters;
    wire ui_audio_ready, rack_in_valid, mixer_in_valid;
    wire [544:0] ui_display_state;
    wire ui_display_valid, ui_display_ready;
    wire lcd_protocol_error, lcd_configuration_error;
    wire signed [15:0] played_pcm;
    wire played_pcm_valid, played_pcm_ready;
    wire [3:0] button_states;
    wire button_valid, button_ready;
    wire [7:0] knob_states, knob_dirs, knob_pressed;
    wire [7:0] knob_physical_states, knob_physical_dirs, knob_physical_pressed;
    wire knob_valid, knob_ready, knob_overflow, knob_scan_error;
    wire adc_error, keyboard_adc_error, keyboard_event_overflow, bend_error;
    wire [2:0] menu_page;
    wire [1:0] menu_selection;
    wire storage_out_valid, storage_out_ready, storage_out_write;
    wire [3:0] storage_out_slot;
    wire [511:0] storage_out_data;
    wire storage_in_valid, storage_in_ready, storage_catalog_valid;
    wire [2:0] storage_in_status;
    wire [511:0] storage_in_data;
    wire [15:0] storage_slot_present;
    assign ui_parameters = {ui_reverb_mix, ui_reverb_make_up, ui_reverb_feedback, ui_reverb_damping, ui_delay_mix, ui_delay_make_up, ui_delay_time, ui_delay_feedback, ui_distortion_mix, ui_distortion_make_up, ui_distortion_gain, ui_distortion_tone, ui_chorus_mix, ui_chorus_make_up, ui_chorus_rate, ui_chorus_depth, ui_balance_volume, ui_master_volume};
    assign {mix_reverb_mix, mix_reverb_make_up, mix_reverb_feedback, mix_reverb_damping, mix_delay_mix, mix_delay_make_up, mix_delay_time, mix_delay_feedback, mix_distortion_mix, mix_distortion_make_up, mix_distortion_gain, mix_distortion_tone, mix_chorus_mix, mix_chorus_make_up, mix_chorus_rate, mix_chorus_depth, mix_balance_volume, mix_master_volume} = mix_parameters;
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
    wire pressure_req_valid, pressure_req_ready, pressure_result_valid;
    wire pressure_result_ready, pressure_sample_error;
    wire [13:0] pressure_result_code;
    wire bend_req_valid, bend_req_ready, bend_result_valid;
    wire bend_result_ready, bend_sample_error, bend_valid, bend_ready;
    wire [13:0] bend_result_code;
    wire [15:0] bend_driver_value [0:0];
    keyboard_driver #(
        .KEY_NUM(KEY_NUM), .DEBOUNCE_TICKS(KEY_DEBOUNCE_TICKS),
        .PRESSURE_ENABLE(1), .ADC_EXTERNAL(1),
        .PRESSURE_ZERO_CODES(PRESSURE_ZERO_CODES),
        .PRESSURE_FULL_CODES(PRESSURE_FULL_CODES),
        .PRESSURE_DEADBAND_CODE(PRESSURE_DEADBAND_CODE),
        .MUX_SETTLE_TICKS(MUX_SETTLE_TICKS),
        .ADC_STARTUP_TICKS(ADC_STARTUP_TICKS)
    ) keyboard_driver_u (
        .clk_sys(clk_sys), .rst_n(rst_sys_n), .scan_tick_up(scan_tick_up),
        .data_a(data_a), .data_b(data_b),
        .out_ready(keyboard_ready), .load_n(load_n), .key_clk(key_clk),
        .key_states(key_states), .key_velocity(key_velocity),
        .out_valid(keyboard_valid),
        .mux_addr(mux_addr), .mux_en_a_n(mux_en_a_n), .mux_en_b_n(mux_en_b_n),
        .adc_error(keyboard_adc_error), .event_overflow(keyboard_event_overflow),
        .pressure_adc_req_valid(pressure_req_valid), .pressure_adc_req_ready(pressure_req_ready),
        .pressure_adc_result_valid(pressure_result_valid), .pressure_adc_result_ready(pressure_result_ready),
        .pressure_adc_result_code(pressure_result_code), .pressure_adc_sample_error(pressure_sample_error),
        .pressure_adc_fault(adc_error)
    );

    pitch_bend_driver #(
        .ADC_EXTERNAL(1), .ADC_STARTUP_TICKS(ADC_STARTUP_TICKS),
        .DEBOUNCE_TICKS(BEND_DEBOUNCE_TICKS), .FILTER_SHIFT(BEND_FILTER_SHIFT),
        .INPUT_SETTLE_TICKS(BEND_SETTLE_TICKS)
    ) pitch_bend_driver_u (
        .clk_sys(clk_sys), .rst_n(rst_sys_n), .scan_tick_up(scan_tick_up),
        .out_ready(bend_ready), .bend_value(bend_driver_value), .out_valid(bend_valid),
        .adc_error(bend_error),
        .adc_req_valid(bend_req_valid), .adc_req_ready(bend_req_ready),
        .adc_result_valid(bend_result_valid), .adc_result_ready(bend_result_ready),
        .adc_result_code(bend_result_code), .adc_sample_error(bend_sample_error),
        .adc_fault(adc_error)
    );

    shared_adc_manager #(
        .SETTLE_TICKS(SHARED_SETTLE_TICKS), .ADC_STARTUP_TICKS(ADC_STARTUP_TICKS)
    ) shared_adc_manager_u (
        .clk_sys(clk_sys), .rst_n(rst_sys_n),
        .pressure_req_valid(pressure_req_valid), .pressure_req_ready(pressure_req_ready),
        .pressure_result_valid(pressure_result_valid), .pressure_result_ready(pressure_result_ready),
        .pressure_result_code(pressure_result_code), .pressure_sample_error(pressure_sample_error),
        .bend_req_valid(bend_req_valid), .bend_req_ready(bend_req_ready),
        .bend_result_valid(bend_result_valid), .bend_result_ready(bend_result_ready),
        .bend_result_code(bend_result_code), .bend_sample_error(bend_sample_error),
        .adc_error(adc_error)
    );

    knob_driver #(
        .KNOB_NUM(8), .TRANSITIONS_PER_STEP(KNOB_TRANSITIONS_PER_STEP),
        .DIRECTION_INVERT(KNOB_DIRECTION_INVERT),
        .DEBOUNCE_TICKS(KNOB_DEBOUNCE_TICKS)
    ) knob_driver_u (
        .clk_sys(clk_sys), .rst_n(rst_sys_n), .scan_tick_up(scan_tick_up),
        .serial_data(knob_serial_data), .out_ready(knob_ready),
        .load_n(knob_load_n), .shift_clk(knob_shift_clk),
        .knob_states(knob_physical_states), .knob_dirs(knob_physical_dirs),
        .knob_pressed(knob_physical_pressed), .out_valid(knob_valid),
        .overflow(knob_overflow), .scan_error(knob_scan_error)
    );
    genvar knob_index;
    generate
        for (knob_index = 0; knob_index < 8; knob_index = knob_index + 1)
        begin : reverse_knob_order
            assign knob_states[knob_index] = knob_physical_states[7-knob_index];
            assign knob_dirs[knob_index] = knob_physical_dirs[7-knob_index];
            assign knob_pressed[knob_index] = knob_physical_pressed[7-knob_index];
        end
    endgenerate

    // 外接 B1～B4 按下为高，直接送入按键驱动。
    button_driver #(.DEBOUNCE_CYCLES(BUTTON_DEBOUNCE_CYCLES)) button_driver_u (
        .clk_sys(clk_sys), .rst_n(rst_sys_n), .scan_tick_up(scan_tick_up),
        .button_pins(ui_button), .out_ready(button_ready),
        .button_states(button_states), .out_valid(button_valid)
    );

    wire [KEY_NUM-1:0] key_frame;
    wire [15:0] velocity_frame [KEY_NUM-1:0];
    wire [3:0] button_frame;
    wire [7:0] knob_steps_frame, knob_dirs_frame, knob_pressed_frame;
    wire [15:0] bend_value [0:0];
    wire combined_valid;
    ui_peripheral_bridge #(.KEY_NUM(KEY_NUM)) ui_peripheral_bridge_u (
        .clk_sys(clk_sys), .rst_n(rst_sys_n),
        .keyboard_states(key_states), .keyboard_velocity(key_velocity),
        .keyboard_valid(keyboard_valid), .keyboard_ready(keyboard_ready),
        .button_states(button_states), .button_valid(button_valid), .button_ready(button_ready),
        .knob_states(knob_states), .knob_dirs(knob_dirs), .knob_pressed(knob_pressed),
        .knob_valid(knob_valid), .knob_ready(knob_ready),
        .bend_value(bend_driver_value[0]), .bend_valid(bend_valid), .bend_ready(bend_ready),
        .key_frame(key_frame), .velocity_frame(velocity_frame), .button_frame(button_frame),
        .knob_states_frame(knob_steps_frame), .knob_dirs_frame(knob_dirs_frame),
        .knob_pressed_frame(knob_pressed_frame), .bend_frame(bend_value[0]),
        .in_valid(combined_valid), .in_ready(ui_in_ready)
    );

    wire [MAX_POLYPHONY-1:0] note_on, note_off, note_busy;
    wire [31:0] note_freq [MAX_POLYPHONY-1:0];
    wire [15:0] note_velocity [MAX_POLYPHONY-1:0];
    wire [3:0] wavetable_0 [0:0];
    wire [3:0] wavetable_1 [0:0];
    wire [15:0] wavetable_interp [0:0];
    wire [15:0] detune [0:0];
    wire [19:0] attack_ticks [0:0];
    wire [19:0] decay_ticks [0:0];
    wire [15:0] sustain_level [0:0];
    wire [19:0] release_ticks [0:0];
    wire ui_out_valid, rack_in_ready;
    wire note_busy_valid, note_busy_ready;
    wire configuration_error, sample_overrun;

    user_interface #(
        .KEY_NUM(KEY_NUM), .MAX_POLYPHONY(MAX_POLYPHONY),
        .CHANNEL_NUM(1), .WAVE_SELECT_STEPS(WAVE_SELECT_STEPS)
    ) user_interface_u (
        .clk_sys(clk_sys), .rst_n(rst_sys_n), .scan_tick_up(scan_tick_up),
        .key_states(key_frame), .key_velocity(velocity_frame),
        .knob_states(knob_steps_frame), .knob_dirs(knob_dirs_frame), .knob_pressed(knob_pressed_frame),
        .bend_value(bend_value), .button_states(button_frame),
        .note_busy(note_busy), .note_busy_valid(note_busy_valid),
        .note_busy_ready(note_busy_ready), .note_on(note_on), .note_off(note_off),
        .note_freq(note_freq), .note_velocity(note_velocity),
        .wavetable_0(wavetable_0), .wavetable_1(wavetable_1),
        .wavetable_interp(wavetable_interp), .detune(detune),
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
        .detune(detune[0]), .attack_ticks(attack_ticks[0]),
        .decay_ticks(decay_ticks[0]), .sustain_level(sustain_level[0]),
        .release_ticks(release_ticks[0]),
        .wavetable_0(wavetable_0[0]), .wavetable_1(wavetable_1[0]),
        .wavetable_interp(wavetable_interp[0]),
        .audio_out(rack_audio), .out_ready(rack_out_ready),
        .in_valid(rack_in_valid), .out_valid(rack_out_valid), .in_ready(rack_in_ready)
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
        .in_valid(mixer_in_valid), .in_ready(mixer_in_ready),
        .out_valid(mixer_out_valid), .out_ready(i2s_ready)
    );

    audio_parameter_bridge #(.PARAM_WIDTH(280)) audio_parameter_bridge_u (
        .clk_sys(clk_sys), .rst_n(rst_sys_n),
        .ui_parameters(ui_parameters), .mixer_parameters(mix_parameters),
        .ui_out_valid(ui_out_valid), .ui_out_ready(ui_audio_ready),
        .rack_in_valid(rack_in_valid), .rack_in_ready(rack_in_ready),
        .rack_out_valid(rack_out_valid), .rack_out_ready(rack_out_ready),
        .mixer_in_valid(mixer_in_valid), .mixer_in_ready(mixer_in_ready)
    );

    reg output_started_r, sample_seen_r, underrun_r;
    reg [15:0] frame_count_r;
    wire sample_fire = mixer_out_valid && i2s_ready;
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
                sample_seen_r <= sample_fire;
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
    // 板载 LED 低电平点亮：节拍、系统故障、菜单页、旋钮扫描故障。
    assign status_led[0] = ~frame_count_r[14];
    assign status_led[1] = ~(underrun_r | configuration_error | sample_overrun |
                             lcd_protocol_error | lcd_configuration_error |
                             adc_error | keyboard_adc_error | bend_error | keyboard_event_overflow);
    assign status_led[5] = ~(knob_overflow | knob_scan_error);

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
