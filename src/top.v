/**
 * 正式整机连接顶层：键盘→UI→声部机架→Mixer→I2S。
 * 真实UI显示快照与I2S实际播放PCM接入LCD交互、第三版绘图及FFT，不产生演示图案或人工演奏数据。
 * LCD场景在安全扫描帧边界提交；SW5/U4为高有效复位，业务复位在PLL锁定后同步释放。
 * 物理旋钮/弯音输入按当前整机范围保留为空闲事件和中心值。
 */
module top
#(
    parameter BUTTON_DEBOUNCE_CYCLES = 2000000,
    parameter KEY_DEBOUNCE_TICKS = 200000,
    parameter WAVE_SELECT_STEPS = 4, // Existing integration value, configurable.
    parameter FLASH_HALF_PERIOD_CYCLES = 50,
    parameter FLASH_POWER_UP_CYCLES = 1000000
)( 
    input clk_core,
    input reset_button,
    input [3:0] ui_button_n,
    input data_a,
    input data_b,
    output load_n,
    output key_clk,
    output i2s_bclk,
    output i2s_lrck,
    output i2s_dout,
    output sd_mode_n,
    output [1:0] status_led,
    output [1:0] saved_value_led,
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
    wire rst_n = ~reset_button;
    reg [279:0] mix_parameters_r;
    reg mix_parameters_busy_r;
    wire ui_audio_ready;
    wire [544:0] ui_display_state;
    wire ui_display_valid, ui_display_ready;
    wire lcd_protocol_error, lcd_configuration_error;
    wire signed [15:0] played_pcm;
    wire played_pcm_valid, played_pcm_ready;
    wire [3:0] button_sync;
    reg [3:0] button_states_r;
    localparam BUTTON_COUNTER_WIDTH = (BUTTON_DEBOUNCE_CYCLES > 1) ? $clog2(BUTTON_DEBOUNCE_CYCLES) : 1;
    genvar button_index;
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
    wire keyboard_valid, ui_in_ready;
    keyboard_driver #(
        .KEY_NUM(KEY_NUM), .DEBOUNCE_TICKS(KEY_DEBOUNCE_TICKS)
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
    wire note_busy_valid, note_busy_ready;
    wire configuration_error, sample_overrun;
    wire [15:0] bend_value [0:0];
    assign bend_value[0] = 16'h8000;

    user_interface #(
        .KEY_NUM(KEY_NUM), .MAX_POLYPHONY(MAX_POLYPHONY),
        .CHANNEL_NUM(1), .WAVE_SELECT_STEPS(WAVE_SELECT_STEPS)
    ) user_interface_u (
        .clk_sys(clk_sys), .rst_n(rst_sys_n), .scan_tick_up(scan_tick_up),
        .key_states(key_states), .key_velocity(key_velocity),
        .knob_states(8'd0), .knob_dirs(8'd0), .knob_pressed(8'd0),
        .bend_value(bend_value), .button_states(button_states_r),
        .note_busy(note_busy), .note_busy_valid(note_busy_valid),
        .note_busy_ready(note_busy_ready), .note_on(note_on), .note_off(note_off),
        .note_freq(note_freq), .note_velocity(note_velocity),
        .wavetable_0(wavetable_0), .wavetable_1(wavetable_1),
        .wavetable_interp(wavetable_interp), .init_phase(init_phase),
        .attack_ticks(attack_ticks), .decay_ticks(decay_ticks),
        .sustain_level(sustain_level), .release_ticks(release_ticks),
        .smp_tick_up(smp_tick_up),
        .in_valid(keyboard_valid), .in_ready(ui_in_ready),
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
    assign status_led = {underrun_r | configuration_error | sample_overrun | lcd_protocol_error | lcd_configuration_error,
                         frame_count_r[14]};

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

    signal_sync #(.W(4), .INITIAL_VALUE(4'b1111)) button_sync_u (
        .clk(clk_sys), .rst_n(rst_sys_n), .signal_in(ui_button_n), .signal_out(button_sync)
    );
    generate
        for (button_index = 0; button_index < 4; button_index = button_index + 1)
        begin : button_filters
            reg [BUTTON_COUNTER_WIDTH-1:0] counter_r;
            always @(posedge clk_sys or negedge rst_sys_n)
            begin
                if (!rst_sys_n)
                begin
                    counter_r <= {BUTTON_COUNTER_WIDTH{1'b0}};
                    button_states_r[button_index] <= 1'b0;
                end
                else if ((!button_sync[button_index]) == button_states_r[button_index])
                    counter_r <= {BUTTON_COUNTER_WIDTH{1'b0}};
                else if (counter_r == BUTTON_DEBOUNCE_CYCLES - 1)
                begin
                    counter_r <= {BUTTON_COUNTER_WIDTH{1'b0}};
                    button_states_r[button_index] <= !button_sync[button_index];
                end
                else counter_r <= counter_r + 1'b1;
            end
        end
    endgenerate
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
    assign saved_value_led = ~{storage_catalog_valid, storage_out_valid};

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
