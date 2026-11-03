/**
 * 2026-11-02 S2和弦接口/逻辑变动：按钮先确定同批play_mode，再按32位批号与琴键帧配对；批号错误锁存configuration_error。音频外部接口不变，545位快照[509:511]新含义；本轮不接LCD。
 */
/**
 * 2026-10-31：两路增益统一UQ1.15，默认1.0（8000）；音色只保存balance，不保存master。
 * 用户交互顶层 v6（S2 K4与八项高级参数）
 * S2：master_volume与balance_volume独立保留，八项高级参数经过最新/采样/输出缓存，背压稳定。
 * 解决note_busy通道回收问题
 * v5 版本修改：采样沿暂存参数，下一拍分组装载；音符与参数仍整组握手。
 * 处理琴键、压力、按钮、旋钮、弯音和音色菜单，向音频输出音符及音色参数。
 * 弯音由键盘流水计算：最终频率 = 基频 * 弯音倍率，内部使用 LUT 查表／乘法，不使用 DSP。
 */

/**
 * 输入在 in_valid && in_ready 时锁存完整帧，包含 bend_value；rst_n 接 rst_sys_n。
 * smp_tick_up 启动计算，out_valid && out_ready 时整组交付，等待时保持 valid 和数据。
 * 当前 32 声部最早在采样 tick 后第 106 沿交付；接收端必须按握手判断，不依赖固定拍数。
 * bend_value[0]: 中心为 16'h8000；弯音影响包括尾音在内的占用声部，菜单中仍有效。
 * NOTE: 相对 S1，ADR 改为 20 位采样周期数，新增总音量、四种干湿比、按钮／采样／错误接口。
 * NOTE: 新增菜单和存储接口；成功读取目前仅恢复参数，不清音，待音频接口确定。
 * NOTE: 键盘与参数各取采样前已完成的结果，不保证同一输入的改动在同一采样生效。
 * NOTE: 一次只允许一组待返回音频结果，反馈回收完成后才处理下一组键盘映射。
 */
module user_interface
#(
    parameter KEY_NUM = 24,  // 琴键数量，1～24，按 C4 起连续编号
    parameter KNOB_NUM = 8,  // 旋钮数量；完整 UI 当前使用 8 个
    parameter BEND_NUM = 1,  // 弯音轮数量，当前只支持 1 路
    parameter MAX_POLYPHONY = 32,  // 声部数量，默认 32
    parameter CHANNEL_NUM = 1,  // 音色通道数量，当前只支持 1
    parameter SMP_TICK_FREQ = 48000,  // 采样率，Hz，用于把毫秒换算成采样周期数
    parameter WAVE_SELECT_STEPS = 0,  // 换一张波形所需步数；0 表示未配置
    parameter [15:0] VELOCITY_SLEW_STEP = 16'd274  // 每次采样最大力度变化，UQ0.16 编码；274 对应满程约 5 ms（48 kHz）
)(
    input clk_sys,
    input rst_n,
    input scan_tick_up,
    input [KEY_NUM-1:0] key_states,
    input [15:0] key_velocity [KEY_NUM-1:0],
    input [KNOB_NUM-1:0] knob_states,  //当前约定 `knob_states[i]=1` 表示这次有一步转动
    input [KNOB_NUM-1:0] knob_dirs,
    input [KNOB_NUM-1:0] knob_pressed,
    input [15:0] bend_value [BEND_NUM-1:0],  // 下端 0000、中心 8000、上端 ffff
    input [MAX_POLYPHONY-1:0] note_busy,
    input note_busy_valid,
    output note_busy_ready,  // 与机架的声部状态快照独立握手
    output [MAX_POLYPHONY-1:0] note_on,
    output [MAX_POLYPHONY-1:0] note_off,
    output [31:0] note_freq [MAX_POLYPHONY-1:0],
    output [15:0] note_velocity [MAX_POLYPHONY-1:0],
    output [3:0] wavetable_0 [CHANNEL_NUM-1:0],
    output [3:0] wavetable_1 [CHANNEL_NUM-1:0],
    output [15:0] wavetable_interp [CHANNEL_NUM-1:0],
    output [15:0] detune [CHANNEL_NUM-1:0],
    output [19:0] attack_ticks [CHANNEL_NUM-1:0],
    output [19:0] decay_ticks [CHANNEL_NUM-1:0],
    output [15:0] sustain_level [CHANNEL_NUM-1:0],
    output [19:0] release_ticks [CHANNEL_NUM-1:0],
    input out_ready,
    input in_valid,
    output out_valid,
    output in_ready,
    // 相对 S1 新增：按钮状态、采样节拍、总音量、效果干湿比和错误指示。
    input [3:0] button_states,
    input smp_tick_up,
    output [15:0] master_volume,  // UQ1.15，0000..FFFF，默认8000；独立总增益，不随音色保存
    output [15:0] reverb_feedback,
    output [15:0] reverb_damping,
    output [15:0] delay_time,
    output [15:0] delay_feedback,
    output [15:0] distortion_gain,
    output [15:0] distortion_tone,
    output [15:0] chorus_rate,
    output [7:0] chorus_depth,
    output [15:0] balance_volume,  // 音色自身增益UQ1.15，随存取变化；master_volume不参与存取
    output [15:0] reverb_mix,
    output [15:0] delay_mix,
    output [15:0] distortion_mix,
    output [15:0] chorus_mix,
    output [15:0] reverb_make_up,
    output [15:0] delay_make_up,
    output [15:0] distortion_make_up,
    output [15:0] chorus_make_up,
    output configuration_error,
    output sample_overrun,
    // 存储接口以 UI 为参照：out 发请求，in 收结果；槽号 0～15 对应界面 01～16。
    // out_ready 由存储返回，in_ready 由 UI 输出；均按 clk_sys 上升沿握手。
    output storage_out_valid,
    input storage_out_ready,
    output storage_out_write,
    output [3:0] storage_out_slot,
    output [511:0] storage_out_data,
    input storage_in_valid,
    output storage_in_ready,
    input [2:0] storage_in_status,
    input [511:0] storage_in_data,
    output [1:0] menu_effect,
    output menu_effect_reset,
    output [127:0] menu_advanced_parameters,
    output [2:0] menu_page,
    output [2:0] menu_selection,
    output menu_autoplay_active,
    output autoplay_song,
    output autoplay_running,
    input autoplay_done,
    output [3:0] menu_slot,
    output menu_save,
    output [3:0] menu_result_status,
    input storage_catalog_valid,
    input [15:0] storage_slot_present,
    output menu_slot_known,
    output menu_slot_present,
    // NEW LCD display channel, V2. Same clk_sys and rst_sys_n as this UI.
    // state[31:0] seq; [223:32]12 edit-unit words; [239:224]master Q15;
    // [255:240]balance Q15; [383:256]8 advanced words; [399:384]signed
    // wave progress; [415:400]steps; [419:416]mode/fine/target;
    // [453:420]menu/catalog; [455:454]configuration_error/sample_overrun;
    // [477:456]activity22; [499:478]reset22; [500]view0=WAVE/1=FFT;
    // [506:501]busy count; [507]busy-known; [508]bend-known;
    // On play page [509] is play_mode. On menu page it marks AutoPlay;
    // [510] marks a submenu and [511] is its selected option/song.
    // [527:512]calibrated bend request (0000/8000/FFFF).
    // [543:528]selected effect make-up UQ1.15; [544]extension valid.
    // Transfer only on display_out_valid && display_out_ready. While waiting,
    // hold the full545-bit state and valid. Display ready never gates existing
    // input, audio, note_busy or storage ready. Old unsent models may coalesce;
    // activity/reset events are OR-preserved. No keyboard-lighting payload.
    output [544:0] display_out_state,
    output display_out_valid,
    input display_out_ready
);
    localparam STATE_WAIT_COMBINED_FRAME = 1'b0;
    localparam STATE_DELIVER_FRAME_TO_ALL_SOURCES = 1'b1;
    wire display_pipeline_commit;
    wire [512:0] display_pipeline_payload;
    wire current_state;
    reg next_state;
    reg [31:0] next_batch_id_r;
    reg [31:0] batch_id_r;
    reg [3:0] button_frame_r;
    reg [7:0] knob_states_r;
    reg [7:0] knob_dirs_r;
    reg [7:0] knob_pressed_r;
    reg button_delivered_r;
    reg knob_delivered_r;
    reg keyboard_delivered_r;
    reg [KEY_NUM-1:0] key_frame_r;
    reg [15:0] bend_frame_r;
    reg [15:0] pressure_frame_r [KEY_NUM-1:0];
    wire keyboard_input_valid;
    wire keyboard_context_valid, keyboard_context_ready, keyboard_context_play_mode;
    wire [31:0] keyboard_context_batch_id;
    wire keyboard_context_matches = keyboard_context_batch_id == batch_id_r;
    reg keyboard_context_error_r;
    wire keyboard_input_ready;
    wire keyboard_audio_valid;
    wire keyboard_sample_ready;
    wire keyboard_overrun;
    wire audio_accept;
    wire input_frame_available;
    integer key_index;
    wire button_valid;
    wire knob_valid;
    wire button_ready;
    wire knob_ready;
    wire pipeline_valid;
    wire pipeline_configuration_error;
    wire pipeline_protocol_error;
    reg out_valid_r;
    reg sample_overrun_r;

    wire sample_capture_accept;
    // 三组同沿预约、下一沿同时装载；宽参数不再由实时握手判断直接控制。
    reg wave_capture_pending_r /* synthesis syn_preserve = 1 */;
    reg envelope_capture_pending_r /* synthesis syn_preserve = 1 */;
    reg mix_capture_pending_r /* synthesis syn_preserve = 1 */;
    // 暂存与采样沿相同的版本，不读取下一拍可能已更新的 latest 参数。
    reg [3:0] sampled_wavetable_0_r;
    reg [3:0] sampled_wavetable_1_r;
    reg [15:0] sampled_wavetable_interp_r;
    reg [15:0] sampled_detune_r;
    reg [19:0] sampled_attack_ticks_r;
    reg [19:0] sampled_decay_ticks_r;
    reg [15:0] sampled_sustain_level_r;
    reg [19:0] sampled_release_ticks_r;
    reg [15:0] sampled_master_volume_r;
    reg [15:0] sampled_balance_volume_r;
    reg [7:0] sampled_chorus_depth_r;
    reg [15:0] sampled_chorus_rate_r;
    reg [15:0] sampled_distortion_tone_r;
    reg [15:0] sampled_distortion_gain_r;
    reg [15:0] sampled_delay_feedback_r;
    reg [15:0] sampled_delay_time_r;
    reg [15:0] sampled_reverb_damping_r;
    reg [15:0] sampled_reverb_feedback_r;
    reg [15:0] sampled_reverb_mix_r;
    reg [15:0] sampled_delay_mix_r;
    reg [15:0] sampled_distortion_mix_r;
    reg [15:0] sampled_chorus_mix_r;
    reg [63:0] sampled_make_up_r;
    genvar channel_index;
    wire [3:0] pipeline_wavetable_0 [0:0];
    reg [3:0] latest_wavetable_0_r;
    reg [3:0] output_wavetable_0_r;
    wire [3:0] pipeline_wavetable_1 [0:0];
    reg [3:0] latest_wavetable_1_r;
    reg [3:0] output_wavetable_1_r;
    wire [15:0] pipeline_wavetable_interp [0:0];
    reg [15:0] latest_wavetable_interp_r;
    reg [15:0] output_wavetable_interp_r;
    wire [15:0] pipeline_detune [0:0];
    reg [15:0] latest_detune_r;
    reg [15:0] output_detune_r;
    wire [19:0] pipeline_attack_ticks [0:0];
    reg [19:0] latest_attack_ticks_r;
    reg [19:0] output_attack_ticks_r;
    wire [19:0] pipeline_decay_ticks [0:0];
    reg [19:0] latest_decay_ticks_r;
    reg [19:0] output_decay_ticks_r;
    wire [15:0] pipeline_sustain_level [0:0];
    reg [15:0] latest_sustain_level_r;
    reg [15:0] output_sustain_level_r;
    wire [19:0] pipeline_release_ticks [0:0];
    reg [19:0] latest_release_ticks_r;
    reg [19:0] output_release_ticks_r;
    wire [15:0] pipeline_master_volume;
    wire [15:0] pipeline_balance_volume;
    wire [7:0] pipeline_chorus_depth;
    wire [15:0] pipeline_chorus_rate;
    wire [15:0] pipeline_distortion_tone;
    wire [15:0] pipeline_distortion_gain;
    wire [15:0] pipeline_delay_feedback;
    wire [15:0] pipeline_delay_time;
    wire [15:0] pipeline_reverb_damping;
    wire [15:0] pipeline_reverb_feedback;
    reg [15:0] latest_master_volume_r;
    reg [15:0] latest_balance_volume_r;
    reg [7:0] latest_chorus_depth_r;
    reg [15:0] latest_chorus_rate_r;
    reg [15:0] latest_distortion_tone_r;
    reg [15:0] latest_distortion_gain_r;
    reg [15:0] latest_delay_feedback_r;
    reg [15:0] latest_delay_time_r;
    reg [15:0] latest_reverb_damping_r;
    reg [15:0] latest_reverb_feedback_r;
    reg [15:0] output_master_volume_r;
    reg [15:0] output_balance_volume_r;
    reg [7:0] output_chorus_depth_r;
    reg [15:0] output_chorus_rate_r;
    reg [15:0] output_distortion_tone_r;
    reg [15:0] output_distortion_gain_r;
    reg [15:0] output_delay_feedback_r;
    reg [15:0] output_delay_time_r;
    reg [15:0] output_reverb_damping_r;
    reg [15:0] output_reverb_feedback_r;
    wire [15:0] pipeline_reverb_mix;
    reg [15:0] latest_reverb_mix_r;
    reg [15:0] output_reverb_mix_r;
    wire [15:0] pipeline_delay_mix;
    reg [15:0] latest_delay_mix_r;
    reg [15:0] output_delay_mix_r;
    wire [15:0] pipeline_distortion_mix;
    reg [15:0] latest_distortion_mix_r;
    reg [15:0] output_distortion_mix_r;
    wire [15:0] pipeline_chorus_mix;
    reg [15:0] latest_chorus_mix_r;
    reg [15:0] output_chorus_mix_r;
    wire [15:0] pipeline_reverb_make_up, pipeline_delay_make_up;
    wire [15:0] pipeline_distortion_make_up, pipeline_chorus_make_up;
    reg [63:0] latest_make_up_r, output_make_up_r;

    assign keyboard_context_ready = (current_state == STATE_DELIVER_FRAME_TO_ALL_SOURCES)
        && !keyboard_delivered_r && keyboard_context_matches && keyboard_input_ready;
    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n) keyboard_context_error_r <= 1'b0;
        else if (current_state == STATE_DELIVER_FRAME_TO_ALL_SOURCES && keyboard_context_valid
                 && !keyboard_delivered_r && !keyboard_context_matches) keyboard_context_error_r <= 1'b1;
    end
    assign configuration_error = pipeline_configuration_error || pipeline_protocol_error || keyboard_context_error_r ||
        (CHANNEL_NUM != 1) || (KNOB_NUM != 8) || (BEND_NUM != 1) || (KEY_NUM < 1) || (KEY_NUM > 24) ||
        (SMP_TICK_FREQ < 1000) || (SMP_TICK_FREQ > 209715) ||
        (MAX_POLYPHONY < 1) || (VELOCITY_SLEW_STEP == 16'd0);
    assign input_frame_available = !configuration_error && (current_state == STATE_WAIT_COMBINED_FRAME);
    assign in_ready = rst_n && input_frame_available;
    assign button_valid = (current_state == STATE_DELIVER_FRAME_TO_ALL_SOURCES) && !button_delivered_r;
    assign knob_valid = (current_state == STATE_DELIVER_FRAME_TO_ALL_SOURCES) && !knob_delivered_r;
    assign keyboard_input_valid = (current_state == STATE_DELIVER_FRAME_TO_ALL_SOURCES) && !keyboard_delivered_r
        && keyboard_context_valid && keyboard_context_matches;
    // out_valid_r 与键盘有效状态均异步清零；不重复引入复位组合路径。
    assign out_valid = !configuration_error && out_valid_r && keyboard_audio_valid;
    assign audio_accept = out_valid && out_ready;
    assign sample_capture_accept = smp_tick_up && !configuration_error && keyboard_sample_ready;
    assign sample_overrun = sample_overrun_r || keyboard_overrun;
    keyboard_note_pipeline #(
        .KEY_NUM(KEY_NUM), .MAX_POLYPHONY(MAX_POLYPHONY), .VELOCITY_SLEW_STEP(VELOCITY_SLEW_STEP)
    ) keyboard_note_pipeline_u (
        .clk_sys(clk_sys), .rst_n(rst_n), .scan_tick_up(scan_tick_up),
        .smp_tick_up(smp_tick_up && !configuration_error),
        .play_mode(keyboard_context_play_mode), .key_states(key_frame_r), .key_velocity(pressure_frame_r), .note_busy(note_busy),
        .note_busy_valid(note_busy_valid), .note_busy_ready(note_busy_ready),
        .bend_value(bend_frame_r),
        .in_valid(keyboard_input_valid), .in_ready(keyboard_input_ready),
        .note_on(note_on), .note_off(note_off), .note_freq(note_freq), .note_velocity(note_velocity),
        .out_valid(keyboard_audio_valid), .out_ready(out_ready && out_valid_r && !configuration_error),
        .sample_ready(keyboard_sample_ready), .sample_overrun(keyboard_overrun)
    );
    generate
        for (channel_index=0;channel_index<CHANNEL_NUM;channel_index=channel_index+1)
        begin : parameter_channels
            assign wavetable_0[channel_index] = (channel_index == 0) ? output_wavetable_0_r : 4'd0;
            assign wavetable_1[channel_index] = (channel_index == 0) ? output_wavetable_1_r : 4'd0;
            assign wavetable_interp[channel_index] = (channel_index == 0) ? output_wavetable_interp_r : 16'd0;
            assign detune[channel_index] = (channel_index == 0) ? output_detune_r : 16'd0;
            assign attack_ticks[channel_index] = (channel_index == 0) ? output_attack_ticks_r : 20'd0;
            assign decay_ticks[channel_index] = (channel_index == 0) ? output_decay_ticks_r : 20'd0;
            assign sustain_level[channel_index] = (channel_index == 0) ? output_sustain_level_r : 16'd0;
            assign release_ticks[channel_index] = (channel_index == 0) ? output_release_ticks_r : 20'd0;
        end
    endgenerate
    assign master_volume = output_master_volume_r;
    assign balance_volume = output_balance_volume_r;
    assign chorus_depth = output_chorus_depth_r;
    assign chorus_rate = output_chorus_rate_r;
    assign distortion_tone = output_distortion_tone_r;
    assign distortion_gain = output_distortion_gain_r;
    assign delay_feedback = output_delay_feedback_r;
    assign delay_time = output_delay_time_r;
    assign reverb_damping = output_reverb_damping_r;
    assign reverb_feedback = output_reverb_feedback_r;
    assign reverb_mix = output_reverb_mix_r;
    assign delay_mix = output_delay_mix_r;
    assign distortion_mix = output_distortion_mix_r;
    assign chorus_mix = output_chorus_mix_r;
    assign {chorus_make_up, distortion_make_up, delay_make_up, reverb_make_up} = output_make_up_r;
    fsm #(
        .W(1), .INITIAL_STATE(STATE_WAIT_COMBINED_FRAME)
    ) fsm_u (
        .clk(clk_sys),
        .rst_n(rst_n),
        .stn(next_state),
        .stc(current_state)
    );

    always @(*)
    begin
        next_state = current_state;
        case (current_state)
            STATE_WAIT_COMBINED_FRAME:
                if (in_valid && input_frame_available) next_state = STATE_DELIVER_FRAME_TO_ALL_SOURCES;
            STATE_DELIVER_FRAME_TO_ALL_SOURCES:
                // IF-INPUT-03：只看已登记的交付完成，避免下游 ready 长组合链回到 FSM。
                // 全部接收后多等一拍才开放下一帧；公共输入仍以 valid && ready 交付。
                if (button_delivered_r && knob_delivered_r && keyboard_delivered_r)
                    next_state = STATE_WAIT_COMBINED_FRAME;
            default: next_state = STATE_WAIT_COMBINED_FRAME;
        endcase
    end
    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            next_batch_id_r <= 32'd0;
            batch_id_r <= 32'd0;
            button_frame_r <= 4'd0;
            knob_states_r <= 8'd0;
            knob_dirs_r <= 8'd0;
            knob_pressed_r <= 8'd0;
            button_delivered_r <= 1'b0;
            knob_delivered_r <= 1'b0;
            keyboard_delivered_r <= 1'b0;
            key_frame_r <= '0;
            bend_frame_r <= 16'h8000;
            for (key_index = 0; key_index < KEY_NUM; key_index = key_index + 1)
                pressure_frame_r[key_index] <= 16'd0;
        end
        else
        begin
            if (in_valid && input_frame_available)
            begin
                batch_id_r <= next_batch_id_r;
                next_batch_id_r <= next_batch_id_r + 32'd1;
                button_frame_r <= button_states;
                knob_states_r <= knob_states;
                knob_dirs_r <= knob_dirs;
                knob_pressed_r <= knob_pressed;
                button_delivered_r <= 1'b0;
                knob_delivered_r <= 1'b0;
                keyboard_delivered_r <= 1'b0;
                key_frame_r <= key_states;
                bend_frame_r <= bend_value[0];
                for (key_index = 0; key_index < KEY_NUM; key_index = key_index + 1)
                    pressure_frame_r[key_index] <= key_velocity[key_index];
            end
            if (button_valid && button_ready) button_delivered_r <= 1'b1;
            if (knob_valid && knob_ready) knob_delivered_r <= 1'b1;
            if (keyboard_input_valid && keyboard_input_ready) keyboard_delivered_r <= 1'b1;
        end
    end
    ui_control_pipeline #(
        .WAVE_SELECT_STEPS(WAVE_SELECT_STEPS),
        .SMP_TICK_FREQ(SMP_TICK_FREQ)
    ) ui_control_pipeline_u (
        .storage_out_valid(storage_out_valid),
        .storage_out_ready(storage_out_ready),
        .storage_out_write(storage_out_write),
        .storage_out_slot(storage_out_slot),
        .storage_out_data(storage_out_data),
        .storage_in_valid(storage_in_valid),
        .storage_in_ready(storage_in_ready),
        .storage_in_status(storage_in_status),
        .storage_in_data(storage_in_data),
        .menu_effect(menu_effect), .menu_effect_reset(menu_effect_reset),
        .menu_advanced_parameters(menu_advanced_parameters),
        .menu_page(menu_page),
        .menu_selection(menu_selection),
        .menu_autoplay_active(menu_autoplay_active), .autoplay_song(autoplay_song),
        .autoplay_running(autoplay_running), .autoplay_done(autoplay_done),
        .menu_slot(menu_slot),
        .menu_save(menu_save),
        .menu_result_status(menu_result_status),
        .storage_catalog_valid(storage_catalog_valid),
        .storage_slot_present(storage_slot_present),
        .menu_slot_known(menu_slot_known),
        .menu_slot_present(menu_slot_present),
        .clk_sys(clk_sys),
        .rst_n(rst_n),
        .scan_tick_up(scan_tick_up),
        .button_states(button_frame_r),
        .button_batch_id(batch_id_r),
        .button_batch_last(1'b1),
        .button_in_valid(button_valid),
        .button_in_ready(button_ready),
        .knob_states(knob_states_r),
        .knob_dirs(knob_dirs_r),
        .knob_pressed(knob_pressed_r),
        .knob_batch_id(batch_id_r),
        .knob_batch_last(1'b1),
        .knob_in_valid(knob_valid),
        .knob_in_ready(knob_ready),
        .keyboard_context_valid(keyboard_context_valid), .keyboard_context_ready(keyboard_context_ready),
        .keyboard_context_batch_id(keyboard_context_batch_id), .keyboard_context_play_mode(keyboard_context_play_mode),
        .display_model_commit(display_pipeline_commit),
        .display_model_payload(display_pipeline_payload),
        .out_valid(pipeline_valid),
        .out_ready(1'b1),
        .protocol_error(pipeline_protocol_error),
        .configuration_error(pipeline_configuration_error),
        .wavetable_0(pipeline_wavetable_0),
        .wavetable_1(pipeline_wavetable_1),
        .wavetable_interp(pipeline_wavetable_interp),
        .detune(pipeline_detune),
        .attack_ticks(pipeline_attack_ticks),
        .decay_ticks(pipeline_decay_ticks),
        .sustain_level(pipeline_sustain_level),
        .release_ticks(pipeline_release_ticks),
        .master_volume(pipeline_master_volume),
        .balance_volume(pipeline_balance_volume),
        .chorus_depth(pipeline_chorus_depth),
        .chorus_rate(pipeline_chorus_rate),
        .distortion_tone(pipeline_distortion_tone),
        .distortion_gain(pipeline_distortion_gain),
        .delay_feedback(pipeline_delay_feedback),
        .delay_time(pipeline_delay_time),
        .reverb_damping(pipeline_reverb_damping),
        .reverb_feedback(pipeline_reverb_feedback),
        .reverb_mix(pipeline_reverb_mix),
        .delay_mix(pipeline_delay_mix),
        .distortion_mix(pipeline_distortion_mix),
        .chorus_mix(pipeline_chorus_mix),
        .reverb_make_up(pipeline_reverb_make_up), .delay_make_up(pipeline_delay_make_up),
        .distortion_make_up(pipeline_distortion_make_up), .chorus_make_up(pipeline_chorus_make_up)
    );

    localparam [3:0] DEFAULT_WAVETABLE_0 = 4'd0;
    localparam [3:0] DEFAULT_WAVETABLE_1 = 4'd1;
    localparam [15:0] DEFAULT_WAVETABLE_INTERP = 16'd0;
    localparam [15:0] DEFAULT_DETUNE = 16'd0;
    localparam [19:0] DEFAULT_ATTACK_TICKS = ((64'd5 * SMP_TICK_FREQ + 64'd500) / 64'd1000);
    localparam [19:0] DEFAULT_DECAY_TICKS = ((64'd150 * SMP_TICK_FREQ + 64'd500) / 64'd1000);
    localparam [15:0] DEFAULT_SUSTAIN_LEVEL = 16'd45875;
    localparam [19:0] DEFAULT_RELEASE_TICKS = ((64'd200 * SMP_TICK_FREQ + 64'd500) / 64'd1000);
    localparam [15:0] DEFAULT_MASTER_VOLUME = 16'h8000;  // UQ1.15，1.0
    localparam [15:0] DEFAULT_REVERB_MIX = 16'd0;
    localparam [15:0] DEFAULT_DELAY_MIX = 16'd0;
    localparam [15:0] DEFAULT_DISTORTION_MIX = 16'd0;
    localparam [15:0] DEFAULT_CHORUS_MIX = 16'd0;
    // IF-SAMPLE-CAPTURE-01：E0接受采样并暂存，E1局部分组装载；键盘仍在E0启动。
    // 逐拍暂存避免将长使能路径转移到暂存寄存器；无预约时不影响公开输出。
    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            wave_capture_pending_r <= 1'b0;
            envelope_capture_pending_r <= 1'b0;
            mix_capture_pending_r <= 1'b0;
            sampled_wavetable_0_r <= DEFAULT_WAVETABLE_0;
            sampled_wavetable_1_r <= DEFAULT_WAVETABLE_1;
            sampled_wavetable_interp_r <= DEFAULT_WAVETABLE_INTERP;
            sampled_detune_r <= DEFAULT_DETUNE;
            sampled_attack_ticks_r <= DEFAULT_ATTACK_TICKS;
            sampled_decay_ticks_r <= DEFAULT_DECAY_TICKS;
            sampled_sustain_level_r <= DEFAULT_SUSTAIN_LEVEL;
            sampled_release_ticks_r <= DEFAULT_RELEASE_TICKS;
            sampled_master_volume_r <= DEFAULT_MASTER_VOLUME;
            sampled_balance_volume_r <= 16'h8000;
            sampled_chorus_depth_r <= 8'd24;
            sampled_chorus_rate_r <= 16'd16384;
            sampled_distortion_tone_r <= 16'd32768;
            sampled_distortion_gain_r <= 16'd4096;
            sampled_delay_feedback_r <= 16'd36864;
            sampled_delay_time_r <= 16'd12000;
            sampled_reverb_damping_r <= 16'd10240;
            sampled_reverb_feedback_r <= 16'd45056;
            sampled_reverb_mix_r <= DEFAULT_REVERB_MIX;
            sampled_delay_mix_r <= DEFAULT_DELAY_MIX;
            sampled_distortion_mix_r <= DEFAULT_DISTORTION_MIX;
            sampled_chorus_mix_r <= DEFAULT_CHORUS_MIX;
            sampled_make_up_r <= {4{16'h8000}};
        end
        else
        begin
            wave_capture_pending_r <= sample_capture_accept;
            envelope_capture_pending_r <= sample_capture_accept;
            mix_capture_pending_r <= sample_capture_accept;
            sampled_wavetable_0_r <= latest_wavetable_0_r;
            sampled_wavetable_1_r <= latest_wavetable_1_r;
            sampled_wavetable_interp_r <= latest_wavetable_interp_r;
            sampled_detune_r <= latest_detune_r;
            sampled_attack_ticks_r <= latest_attack_ticks_r;
            sampled_decay_ticks_r <= latest_decay_ticks_r;
            sampled_sustain_level_r <= latest_sustain_level_r;
            sampled_release_ticks_r <= latest_release_ticks_r;
            sampled_master_volume_r <= latest_master_volume_r;
            sampled_balance_volume_r <= latest_balance_volume_r;
            sampled_chorus_depth_r <= latest_chorus_depth_r;
            sampled_chorus_rate_r <= latest_chorus_rate_r;
            sampled_distortion_tone_r <= latest_distortion_tone_r;
            sampled_distortion_gain_r <= latest_distortion_gain_r;
            sampled_delay_feedback_r <= latest_delay_feedback_r;
            sampled_delay_time_r <= latest_delay_time_r;
            sampled_reverb_damping_r <= latest_reverb_damping_r;
            sampled_reverb_feedback_r <= latest_reverb_feedback_r;
            sampled_reverb_mix_r <= latest_reverb_mix_r;
            sampled_delay_mix_r <= latest_delay_mix_r;
            sampled_distortion_mix_r <= latest_distortion_mix_r;
            sampled_chorus_mix_r <= latest_chorus_mix_r;
            sampled_make_up_r <= latest_make_up_r;
        end
    end

    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            out_valid_r <= 1'b0;
            sample_overrun_r <= 1'b0;
            latest_wavetable_0_r <= DEFAULT_WAVETABLE_0;
            output_wavetable_0_r <= DEFAULT_WAVETABLE_0;
            latest_wavetable_1_r <= DEFAULT_WAVETABLE_1;
            output_wavetable_1_r <= DEFAULT_WAVETABLE_1;
            latest_wavetable_interp_r <= DEFAULT_WAVETABLE_INTERP;
            output_wavetable_interp_r <= DEFAULT_WAVETABLE_INTERP;
            latest_detune_r <= DEFAULT_DETUNE;
            output_detune_r <= DEFAULT_DETUNE;
            latest_attack_ticks_r <= DEFAULT_ATTACK_TICKS;
            output_attack_ticks_r <= DEFAULT_ATTACK_TICKS;
            latest_decay_ticks_r <= DEFAULT_DECAY_TICKS;
            output_decay_ticks_r <= DEFAULT_DECAY_TICKS;
            latest_sustain_level_r <= DEFAULT_SUSTAIN_LEVEL;
            output_sustain_level_r <= DEFAULT_SUSTAIN_LEVEL;
            latest_release_ticks_r <= DEFAULT_RELEASE_TICKS;
            output_release_ticks_r <= DEFAULT_RELEASE_TICKS;
            latest_master_volume_r <= DEFAULT_MASTER_VOLUME;
            latest_balance_volume_r <= 16'h8000;
            latest_chorus_depth_r <= 8'd24;
            latest_chorus_rate_r <= 16'd16384;
            latest_distortion_tone_r <= 16'd32768;
            latest_distortion_gain_r <= 16'd4096;
            latest_delay_feedback_r <= 16'd36864;
            latest_delay_time_r <= 16'd12000;
            latest_reverb_damping_r <= 16'd10240;
            latest_reverb_feedback_r <= 16'd45056;
            output_master_volume_r <= DEFAULT_MASTER_VOLUME;
            output_balance_volume_r <= 16'h8000;
            output_chorus_depth_r <= 8'd24;
            output_chorus_rate_r <= 16'd16384;
            output_distortion_tone_r <= 16'd32768;
            output_distortion_gain_r <= 16'd4096;
            output_delay_feedback_r <= 16'd36864;
            output_delay_time_r <= 16'd12000;
            output_reverb_damping_r <= 16'd10240;
            output_reverb_feedback_r <= 16'd45056;
            latest_reverb_mix_r <= DEFAULT_REVERB_MIX;
            output_reverb_mix_r <= DEFAULT_REVERB_MIX;
            latest_delay_mix_r <= DEFAULT_DELAY_MIX;
            output_delay_mix_r <= DEFAULT_DELAY_MIX;
            latest_distortion_mix_r <= DEFAULT_DISTORTION_MIX;
            output_distortion_mix_r <= DEFAULT_DISTORTION_MIX;
            latest_chorus_mix_r <= DEFAULT_CHORUS_MIX;
            output_chorus_mix_r <= DEFAULT_CHORUS_MIX;
            latest_make_up_r <= {4{16'h8000}};
            output_make_up_r <= {4{16'h8000}};
        end
        else
        begin
            if (pipeline_valid)
            begin
                latest_wavetable_0_r <= pipeline_wavetable_0[0];
                latest_wavetable_1_r <= pipeline_wavetable_1[0];
                latest_wavetable_interp_r <= pipeline_wavetable_interp[0];
                latest_detune_r <= pipeline_detune[0];
                latest_attack_ticks_r <= pipeline_attack_ticks[0];
                latest_decay_ticks_r <= pipeline_decay_ticks[0];
                latest_sustain_level_r <= pipeline_sustain_level[0];
                latest_release_ticks_r <= pipeline_release_ticks[0];
                latest_master_volume_r <= pipeline_master_volume;
                latest_balance_volume_r <= pipeline_balance_volume;
                latest_chorus_depth_r <= pipeline_chorus_depth;
                latest_chorus_rate_r <= pipeline_chorus_rate;
                latest_distortion_tone_r <= pipeline_distortion_tone;
                latest_distortion_gain_r <= pipeline_distortion_gain;
                latest_delay_feedback_r <= pipeline_delay_feedback;
                latest_delay_time_r <= pipeline_delay_time;
                latest_reverb_damping_r <= pipeline_reverb_damping;
                latest_reverb_feedback_r <= pipeline_reverb_feedback;
                latest_reverb_mix_r <= pipeline_reverb_mix;
                latest_delay_mix_r <= pipeline_delay_mix;
                latest_distortion_mix_r <= pipeline_distortion_mix;
                latest_chorus_mix_r <= pipeline_chorus_mix;
                latest_make_up_r <= {pipeline_chorus_make_up, pipeline_distortion_make_up,
                    pipeline_delay_make_up, pipeline_reverb_make_up};
            end
            if (audio_accept) out_valid_r <= 1'b0;
            // 参数已装载后才置有效；公开 out_valid 仍等待同批键盘结果就绪。
            if (wave_capture_pending_r)
            begin
                out_valid_r <= 1'b1;
                output_wavetable_0_r <= sampled_wavetable_0_r;
                output_wavetable_1_r <= sampled_wavetable_1_r;
                output_wavetable_interp_r <= sampled_wavetable_interp_r;
                output_detune_r <= sampled_detune_r;
            end
            if (envelope_capture_pending_r)
            begin
                output_attack_ticks_r <= sampled_attack_ticks_r;
                output_decay_ticks_r <= sampled_decay_ticks_r;
                output_sustain_level_r <= sampled_sustain_level_r;
                output_release_ticks_r <= sampled_release_ticks_r;
            end
            if (mix_capture_pending_r)
            begin
                output_master_volume_r <= sampled_master_volume_r;
                output_balance_volume_r <= sampled_balance_volume_r;
                output_chorus_depth_r <= sampled_chorus_depth_r;
                output_chorus_rate_r <= sampled_chorus_rate_r;
                output_distortion_tone_r <= sampled_distortion_tone_r;
                output_distortion_gain_r <= sampled_distortion_gain_r;
                output_delay_feedback_r <= sampled_delay_feedback_r;
                output_delay_time_r <= sampled_delay_time_r;
                output_reverb_damping_r <= sampled_reverb_damping_r;
                output_reverb_feedback_r <= sampled_reverb_feedback_r;
                output_reverb_mix_r <= sampled_reverb_mix_r;
                output_delay_mix_r <= sampled_delay_mix_r;
                output_distortion_mix_r <= sampled_distortion_mix_r;
                output_chorus_mix_r <= sampled_chorus_mix_r;
                output_make_up_r <= sampled_make_up_r;
            end
            if (smp_tick_up && !configuration_error && !keyboard_sample_ready)
                sample_overrun_r <= 1'b1;
        end
    end

    reg [512:0] display_payload;
    reg display_initialized_r;
    reg [3:0] display_busy_group_r [0:3];
    reg display_busy_pending_r, display_busy_known_r, display_bend_known_r;
    reg [5:0] display_busy_count_r;
    reg [15:0] display_bend_r;
    reg [25:0] display_status_previous_r;
    wire [31:0] display_busy_word;
    wire [25:0] display_status = {configuration_error, sample_overrun,
        display_busy_known_r, display_bend_known_r, display_busy_count_r, display_bend_r};
    wire display_status_changed = (display_status != display_status_previous_r);
    wire display_publish = display_pipeline_commit || (display_initialized_r && display_status_changed);
    genvar display_voice;
    generate
        for (display_voice = 0; display_voice < 32; display_voice = display_voice + 1)
        begin : display_busy_bits
            if (display_voice < MAX_POLYPHONY)
                assign display_busy_word[display_voice] = note_busy[display_voice];
            else
                assign display_busy_word[display_voice] = 1'b0;
        end
    endgenerate
    function [3:0] display_popcount8;
        input [7:0] value;
        integer bit_index;
        begin
            display_popcount8 = 4'd0;
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1)
                display_popcount8 = display_popcount8 + {3'd0,value[bit_index]};
        end
    endfunction
    integer display_lane;
    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            display_initialized_r <= 1'b0;
            display_busy_pending_r <= 1'b0;
            display_busy_known_r <= 1'b0;
            display_bend_known_r <= 1'b0;
            display_busy_count_r <= 6'd0;
            display_bend_r <= 16'h8000;
            display_status_previous_r <= 26'h0008000;
            for (display_lane = 0; display_lane < 4; display_lane = display_lane + 1)
                display_busy_group_r[display_lane] <= 4'd0;
        end
        else
        begin
            if (display_pipeline_commit) display_initialized_r <= 1'b1;
            display_status_previous_r <= display_status;
            display_busy_pending_r <= note_busy_valid && note_busy_ready;
            if (note_busy_valid && note_busy_ready)
                for (display_lane = 0; display_lane < 4; display_lane = display_lane + 1)
                    display_busy_group_r[display_lane] <= display_popcount8(display_busy_word[8*display_lane +: 8]);
            if (display_busy_pending_r)
            begin
                display_busy_count_r <= {2'd0,display_busy_group_r[0]} + {2'd0,display_busy_group_r[1]} +
                                        {2'd0,display_busy_group_r[2]} + {2'd0,display_busy_group_r[3]};
                display_busy_known_r <= 1'b1;
            end
            if (in_valid && in_ready)
            begin
                display_bend_r <= bend_value[0];
                display_bend_known_r <= 1'b1;
            end
        end
    end
    always @(*)
    begin
        display_payload = display_pipeline_payload;
        display_payload[422] = configuration_error || (MAX_POLYPHONY > 32);
        display_payload[423] = sample_overrun;
        // Pipeline action bits are pulses; status-only commits must not replay
        // the previous knob action just because the busy count/bend changed.
        if (!display_pipeline_commit) display_payload[467:424] = 44'd0;
        display_payload[474:469] = display_busy_count_r;
        display_payload[475] = display_busy_known_r;
        display_payload[476] = display_bend_known_r;
        // S2 chord fields[479:477] are supplied by the control model, never cleared here.
        display_payload[495:480] = display_bend_r;
    end
    ui_display_snapshot ui_display_snapshot_u (
        .clk_sys(clk_sys), .rst_n(rst_n), .model_commit(display_publish),
        .model_payload(display_payload), .out_state(display_out_state),
        .out_valid(display_out_valid), .out_ready(display_out_ready)
    );
endmodule
