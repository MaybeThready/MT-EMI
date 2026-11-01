/**
 * 24键与24路FSR联合上板测试：真实按键触发对应音符，按住时压力连续控制音量。
 * 复用键盘/压力ADC、UI、32声部机架和I2S；正常时只有按键发声，LED5故障灯熄灭。
 */
/**
 * data_a/data_b、load_n/key_clk：两块12键74HC165板，触摸为1，未触摸为0。
 * mux_addr共接两片4067的S0..S3；mux_en_a_n/mux_en_b_n分别接低有效EN。
 * 第一片Y0..15对应键0..15，第二片Y0..7对应键16..23，COM经原模拟前端接J3 ADCV。
 * PRESSURE_ZERO_CODES/FULL_CODES：每键14位校准码，最低14位对应键0。
 * PRESSURE_DEADBAND_CODE：零点以上的死区码；DEBOUNCE_TICKS：触摸按下/松开稳定周期数。
 * MUX_SETTLE_TICKS：4067选通后的模拟稳定等待，单位为clk_sys周期。
 * AUDIO_SHIFT：混音后算术右移位数，默认2即除4，为和弦留余量；超范围再限幅。
 * UI默认正弦波、5ms起音、150ms衰减、70%持续、200ms释放，按住时最低5%力度。
 * status_led均低亮：0心跳，1有键按住，2/3有按住键压力达到25/75%，4削顶锁存，5故障锁存。
 * rst_n接板载S0；只实例化压力用ADCLRC，不同时接入独立弯音ADC。
 */
module test_velocity
#(
    parameter integer AUDIO_SHIFT = 2,
    parameter integer DEBOUNCE_TICKS = 98304,
    parameter [335:0] PRESSURE_ZERO_CODES = {24{14'd0}},
    parameter [335:0] PRESSURE_FULL_CODES = {24{14'd1690}},
    parameter integer PRESSURE_DEADBAND_CODE = 8,
    parameter integer MUX_SETTLE_TICKS = 4916
)(
    input clk_core,
    input rst_n,
    input data_a,
    input data_b,
    output load_n,
    output key_clk,
    output [3:0] mux_addr,
    output mux_en_a_n,
    output mux_en_b_n,
    output i2s_bclk,
    output i2s_lrck,
    output i2s_dout,
    output sd_mode_n,
    output [5:0] status_led
);
    wire clk_sys, rst_sys_n;

    sys_clocker sys_clocker_u (
        .clk_core(clk_core), .rst_n(rst_n),
        .clk_sys(clk_sys), .rst_sys_n(rst_sys_n)
    );

    test_velocity_core #(
        .AUDIO_SHIFT(AUDIO_SHIFT), .DEBOUNCE_TICKS(DEBOUNCE_TICKS),
        .PRESSURE_ZERO_CODES(PRESSURE_ZERO_CODES), .PRESSURE_FULL_CODES(PRESSURE_FULL_CODES),
        .PRESSURE_DEADBAND_CODE(PRESSURE_DEADBAND_CODE), .MUX_SETTLE_TICKS(MUX_SETTLE_TICKS)
    ) test_velocity_core_u (
        .clk_sys(clk_sys), .rst_n(rst_sys_n), .data_a(data_a), .data_b(data_b),
        .load_n(load_n), .key_clk(key_clk), .mux_addr(mux_addr),
        .mux_en_a_n(mux_en_a_n), .mux_en_b_n(mux_en_b_n),
        .i2s_bclk(i2s_bclk), .i2s_lrck(i2s_lrck), .i2s_dout(i2s_dout),
        .sd_mode_n(sd_mode_n), .status_led(status_led)
    );
endmodule

/**
 * 联合测试核心，与板载PLL分开，便于用真实RTL和ADC协议模型进行回归。
 * clk_sys/rst_n由sys_clocker提供；内部sys_ticker生成所有同步事件脉冲。
 * MAX_POLYPHONY：1～32声部，正式顶层采用默认32；ADC_STARTUP_TICKS默认约1ms。
 * AUTO_KEY_TEST=1仅供诊断：模拟全部触摸有效以取得未屏蔽的24路压力，
 * UI每AUTO_KEY_SAMPLES个音频采样选择一个键；LED0..4低亮显示零基键号。
 * 其余端口和校准参数与上板顶层相同。ADC启动和模拟稳定时间单位均为clk_sys周期。
 */
module test_velocity_core
#(
    parameter integer MAX_POLYPHONY = 32,
    parameter integer AUDIO_SHIFT = 2,
    parameter integer DEBOUNCE_TICKS = 98304,
    parameter [335:0] PRESSURE_ZERO_CODES = {24{14'd0}},
    parameter [335:0] PRESSURE_FULL_CODES = {24{14'd1690}},
    parameter integer PRESSURE_DEADBAND_CODE = 8,
    parameter integer MUX_SETTLE_TICKS = 4916,
    parameter integer ADC_STARTUP_TICKS = 98304,
    parameter integer AUTO_KEY_TEST = 0,
    parameter integer AUTO_KEY_SAMPLES = 96000
)(
    input clk_sys,
    input rst_n,
    input data_a,
    input data_b,
    output load_n,
    output key_clk,
    output [3:0] mux_addr,
    output mux_en_a_n,
    output mux_en_b_n,
    output i2s_bclk,
    output i2s_lrck,
    output i2s_dout,
    output sd_mode_n,
    output [5:0] status_led
);
    localparam integer KEY_NUM = 24;
    localparam integer AUDIO_MSB = 15 + $clog2(MAX_POLYPHONY);
    wire i2s_tick_up, i2s_tick_down, smp_tick_up, scan_tick_up;
    wire [23:0] key_states;
    wire [23:0] driver_key_states;
    wire [15:0] key_velocity [23:0];
    wire keyboard_valid, ui_in_ready, adc_error, event_overflow;
    wire [MAX_POLYPHONY-1:0] note_on, note_off, note_busy;
    wire [31:0] note_freq [MAX_POLYPHONY-1:0];
    wire [15:0] note_velocity [MAX_POLYPHONY-1:0];
    wire [3:0] wavetable_0 [0:0], wavetable_1 [0:0];
    wire [15:0] wavetable_interp [0:0], init_phase [0:0], sustain_level [0:0];
    wire [19:0] attack_ticks [0:0], decay_ticks [0:0], release_ticks [0:0];
    wire [15:0] bend_value [0:0];
    wire ui_out_valid, rack_in_ready, note_busy_valid, note_busy_ready;
    wire configuration_error, sample_overrun;
    wire signed [AUDIO_MSB:0] rack_audio;
    wire signed [AUDIO_MSB:0] scaled_audio;
    wire signed [15:0] limited_audio;
    wire rack_out_valid, i2s_ready, sample_fire, audio_clipped;
    wire signed [15:0] audio_monitor;
    wire audio_monitor_valid;
    wire [23:0] quarter_pressure, high_pressure;
    reg output_started_r, sample_seen_r, underrun_r, clipping_r, fault_r;
    reg [15:0] frame_count_r;
    genvar key;
    localparam integer AUTO_TIMER_W = (AUTO_KEY_SAMPLES > 1) ? $clog2(AUTO_KEY_SAMPLES) : 1;
    reg [AUTO_TIMER_W-1:0] auto_timer_r;
    reg [4:0] auto_key_r;

    assign key_states = AUTO_KEY_TEST ? (24'd1 << auto_key_r) : driver_key_states;

    // 独立诊断只替换触摸输入，压力仍走原驱动、原ADC和原UI/音频链路。
    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            auto_timer_r <= '0;
            auto_key_r <= 5'd0;
        end
        else if (AUTO_KEY_TEST)
        begin
            if (auto_timer_r == AUTO_KEY_SAMPLES - 1)
            begin
                // 只在旧帧真正交付后换键，不能在valid受背压保持时改变输入键号。
                if (keyboard_valid && ui_in_ready)
                begin
                    auto_timer_r <= '0;
                    auto_key_r <= (auto_key_r == 5'd23) ? 5'd0 : auto_key_r + 1'b1;
                end
            end
            else if (smp_tick_up)
                auto_timer_r <= auto_timer_r + 1'b1;
        end
    end

    sys_ticker sys_ticker_u (
        .clk_sys(clk_sys), .rst_n(rst_n),
        .i2s_tick_up(i2s_tick_up), .i2s_tick_down(i2s_tick_down),
        .smp_tick_up(smp_tick_up), .smp_tick_down(),
        .scan_tick_up(scan_tick_up), .scan_tick_down()
    );

    keyboard_driver #(
        .KEY_NUM(KEY_NUM), .PRESSURE_ENABLE(1), .DEBOUNCE_TICKS(DEBOUNCE_TICKS),
        .PRESSURE_ZERO_CODES(PRESSURE_ZERO_CODES), .PRESSURE_FULL_CODES(PRESSURE_FULL_CODES),
        .PRESSURE_DEADBAND_CODE(PRESSURE_DEADBAND_CODE),
        .MUX_SETTLE_TICKS(MUX_SETTLE_TICKS), .ADC_STARTUP_TICKS(ADC_STARTUP_TICKS)
    ) keyboard_driver_u (
        .clk_sys(clk_sys), .rst_n(rst_n), .scan_tick_up(scan_tick_up),
        .data_a(AUTO_KEY_TEST ? 1'b1 : data_a), .data_b(AUTO_KEY_TEST ? 1'b1 : data_b),
        .out_ready(ui_in_ready),
        .load_n(load_n), .key_clk(key_clk), .key_states(driver_key_states),
        .key_velocity(key_velocity), .out_valid(keyboard_valid),
        .mux_addr(mux_addr), .mux_en_a_n(mux_en_a_n), .mux_en_b_n(mux_en_b_n),
        .adc_error(adc_error), .event_overflow(event_overflow)
    );

    assign bend_value[0] = 16'h8000;
    user_interface #(
        .KEY_NUM(KEY_NUM), .MAX_POLYPHONY(MAX_POLYPHONY),
        .CHANNEL_NUM(1), .WAVE_SELECT_STEPS(4)
    ) user_interface_u (
        .clk_sys(clk_sys), .rst_n(rst_n), .scan_tick_up(scan_tick_up), .smp_tick_up(smp_tick_up),
        .key_states(key_states), .key_velocity(key_velocity),
        .knob_states(8'd0), .knob_dirs(8'd0), .knob_pressed(8'd0),
        .bend_value(bend_value), .button_states(4'd0),
        .note_busy(note_busy), .note_busy_valid(note_busy_valid), .note_busy_ready(note_busy_ready),
        .note_on(note_on), .note_off(note_off), .note_freq(note_freq), .note_velocity(note_velocity),
        .wavetable_0(wavetable_0), .wavetable_1(wavetable_1), .wavetable_interp(wavetable_interp),
        .init_phase(init_phase), .attack_ticks(attack_ticks), .decay_ticks(decay_ticks),
        .sustain_level(sustain_level), .release_ticks(release_ticks),
        .in_valid(keyboard_valid), .in_ready(ui_in_ready),
        .out_valid(ui_out_valid), .out_ready(rack_in_ready),
        .master_volume(), .balance_volume(), .reverb_mix(), .delay_mix(),
        .distortion_mix(), .chorus_mix(),
        .reverb_feedback(), .reverb_damping(), .delay_time(), .delay_feedback(),
        .distortion_gain(), .distortion_tone(), .chorus_rate(), .chorus_depth(),
        .configuration_error(configuration_error), .sample_overrun(sample_overrun),
        .storage_out_valid(), .storage_out_ready(1'b0), .storage_out_write(),
        .storage_out_slot(), .storage_out_data(), .storage_in_valid(1'b0), .storage_in_ready(),
        .storage_in_status(3'd0), .storage_in_data(512'd0),
        .storage_catalog_valid(1'b1), .storage_slot_present(16'd0),
        .menu_page(), .menu_selection(), .menu_slot(), .menu_save(),
        .menu_effect(), .menu_effect_reset(), .menu_advanced_parameters(),
        .menu_result_status(), .menu_slot_known(), .menu_slot_present()
    );

    channel_rack #(.MAX_POLYPHONY(MAX_POLYPHONY)) channel_rack_u (
        .clk_sys(clk_sys), .rst_n(rst_n), .smp_tick_up(smp_tick_up),
        .note_on(note_on), .note_off(note_off), .note_busy(note_busy),
        .note_busy_valid(note_busy_valid), .note_busy_ready(note_busy_ready),
        .note_freq(note_freq), .note_velocity(note_velocity),
        .init_phase(init_phase[0]), .attack_ticks(attack_ticks[0]), .decay_ticks(decay_ticks[0]),
        .sustain_level(sustain_level[0]), .release_ticks(release_ticks[0]),
        .wavetable_0(wavetable_0[0]), .wavetable_1(wavetable_1[0]),
        .wavetable_interp(wavetable_interp[0]),
        .audio_out(rack_audio), .out_ready(i2s_ready), .in_valid(ui_out_valid),
        .out_valid(rack_out_valid), .in_ready(rack_in_ready)
    );

    // 固定移位留出复音余量，不引入变量除法。只在真正交付采样时记录削顶。
    assign scaled_audio = rack_audio >>> AUDIO_SHIFT;
    assign audio_clipped = (scaled_audio > 32'sd32767) || (scaled_audio < -32'sd32768);
    assign limited_audio = audio_clipped ?
        (scaled_audio[AUDIO_MSB] ? 16'sh8000 : 16'sh7FFF) : scaled_audio[15:0];
    assign sample_fire = rack_out_valid && i2s_ready;

    i2s_driver i2s_driver_u (
        .clk_sys(clk_sys), .rst_n(rst_n), .i2s_tick_up(i2s_tick_up),
        .i2s_tick_down(i2s_tick_down), .smp_tick_up(smp_tick_up),
        .audio_data(limited_audio), .in_valid(rack_out_valid), .in_ready(i2s_ready),
        .audio_out_lcd(audio_monitor), .out_valid_lcd(audio_monitor_valid), .out_ready_lcd(1'b1),
        .i2s_bclk(i2s_bclk), .i2s_lrck(i2s_lrck), .i2s_dout(i2s_dout), .sd_mode_n(sd_mode_n)
    );

    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            output_started_r <= 1'b0;
            sample_seen_r <= 1'b0;
            underrun_r <= 1'b0;
            clipping_r <= 1'b0;
            fault_r <= 1'b0;
            frame_count_r <= 16'd0;
        end
        else
        begin
            if (sample_fire)
            begin
                output_started_r <= 1'b1;
                if (audio_clipped)
                    clipping_r <= 1'b1;
            end
            if (smp_tick_up)
            begin
                frame_count_r <= frame_count_r + 1'b1;
                if (output_started_r && !sample_seen_r && !sample_fire)
                    underrun_r <= 1'b1;
                sample_seen_r <= sample_seen_r && sample_fire;
            end
            else if (sample_fire)
                sample_seen_r <= 1'b1;
            if (adc_error || event_overflow || configuration_error || sample_overrun || underrun_r)
                fault_r <= 1'b1;
        end
    end

    generate
        for (key = 0; key < KEY_NUM; key = key + 1)
        begin : g_pressure_indicators
            assign quarter_pressure[key] = key_states[key] && (key_velocity[key] >= 16'h4000);
            assign high_pressure[key] = key_states[key] && (key_velocity[key] >= 16'hC000);
        end
    endgenerate
    assign status_led[0] = AUTO_KEY_TEST ? !auto_key_r[0] : !frame_count_r[14];
    assign status_led[1] = AUTO_KEY_TEST ? !auto_key_r[1] : !(|key_states);
    assign status_led[2] = AUTO_KEY_TEST ? !auto_key_r[2] : !(|quarter_pressure);
    assign status_led[3] = AUTO_KEY_TEST ? !auto_key_r[3] : !(|high_pressure);
    assign status_led[4] = AUTO_KEY_TEST ? !auto_key_r[4] : !clipping_r;
    assign status_led[5] = !fault_r;

    // synthesis translate_off
    initial
    begin
        if (MAX_POLYPHONY < 1 || MAX_POLYPHONY > 32 || AUDIO_SHIFT < 0 || AUDIO_SHIFT > 5 ||
            AUTO_KEY_SAMPLES < 1 || (AUTO_KEY_TEST != 0 && AUTO_KEY_TEST != 1))
            $fatal(1, "test_velocity: require 1..32 voices and AUDIO_SHIFT=0..5");
    end
    // synthesis translate_on
endmodule
