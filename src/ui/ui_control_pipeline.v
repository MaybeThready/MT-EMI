/**
 * 连接按钮、旋钮和参数设置模块，输出一整组音色参数。
 * 同一批输入先更新按钮决定的模式、粗细调，再处理旋钮。
 * button_batch_id/knob_batch_id: 配对编号，由 user_interface 自动生成。
 * out_valid/out_ready: 交付更新后的参数；按采样节拍发送由 user_interface 负责。
 * protocol_error: 输入编号或结束标志不匹配；configuration_error: 参数配置非法。
 * WAVE_SELECT_STEPS: 换波形所需步数，0 表示未配置；SMP_TICK_FREQ: 采样率，Hz。
 * rst_n 接 rst_sys_n；所有处理使用 clk_sys。
 */
module ui_control_pipeline
#(
    parameter WAVE_SELECT_STEPS = 0,  // 换一张波形所需步数；0 表示未配置
    parameter BATCH_ID_WIDTH = 32,  // 按钮和旋钮配对编号的位宽
    parameter SMP_TICK_FREQ = 48000  // 采样率，Hz，用于把毫秒换算成采样周期数
)(
    input clk_sys,
    input rst_n,
    input scan_tick_up,
    input [3:0] button_states,
    input [BATCH_ID_WIDTH-1:0] button_batch_id,
    input button_batch_last,
    input button_in_valid,
    output button_in_ready,
    input [7:0] knob_states,
    input [7:0] knob_dirs,
    input [7:0] knob_pressed,
    input [BATCH_ID_WIDTH-1:0] knob_batch_id,
    input knob_batch_last,
    input knob_in_valid,
    output knob_in_ready,
    output [3:0] wavetable_0 [0:0],
    output [3:0] wavetable_1 [0:0],
    output [15:0] wavetable_interp [0:0],
    output [15:0] init_phase [0:0],
    output [19:0] attack_ticks [0:0],
    output [19:0] decay_ticks [0:0],
    output [15:0] sustain_level [0:0],
    output [19:0] release_ticks [0:0],
    output [15:0] master_volume,
    output [15:0] reverb_mix,
    output [15:0] delay_mix,
    output [15:0] distortion_mix,
    output [15:0] chorus_mix,
    output out_valid,
    input out_ready,
    output protocol_error,
    output configuration_error
);
    wire [3:0] handler_button_states;
    wire button_out_valid;
    wire button_out_ready;
    wire [3:0] button_pressed_event;
    wire [3:0] button_released_event;
    wire [3:0] button_held;
    wire button_event_valid;
    wire button_event_ready;
    wire [1:0] context_mode;
    wire context_fine_adjust;
    wire context_edit_enable;
    wire context_edit_target;
    wire context_clear_wave_progress;
    wire context_valid;
    wire context_ready;
    wire [7:0] handler_knob_states;
    wire [7:0] handler_knob_dirs;
    wire [7:0] handler_knob_pressed;
    wire knob_out_valid;
    wire knob_out_ready;
    wire signed [1:0] knob_delta [7:0];
    wire [7:0] knob_pressed_event;
    wire knob_event_valid;
    wire knob_event_ready;
    wire [1:0] mode;
    wire fine_adjust;
    wire edit_enable;
    wire edit_target;
    wire clear_wave_progress;
    wire frame_done_valid;
    wire frame_done_ready;
    wire parameter_valid;
    wire parameter_ready;
    wire [3:0] bank_wavetable_0 [0:0];
    wire [3:0] bank_wavetable_1 [0:0];
    wire [6:0] bank_interp_percent [0:0];
    wire [8:0] bank_phase_degrees [0:0];
    wire [10:0] bank_attack_ms [0:0];
    wire [10:0] bank_decay_ms [0:0];
    wire [6:0] bank_sustain_percent [0:0];
    wire [12:0] bank_release_ms [0:0];
    wire [6:0] bank_master_percent;
    wire [6:0] bank_reverb_mix_percent;
    wire [6:0] bank_delay_mix_percent;
    wire [6:0] bank_distortion_mix_percent;
    wire [6:0] bank_chorus_mix_percent;
    ui_input_frame_joiner #(
        .BATCH_ID_WIDTH(BATCH_ID_WIDTH)
    ) ui_input_frame_joiner_u (
        .clk_sys(clk_sys),
        .rst_n(rst_n),
        .button_states(button_states),
        .button_batch_id(button_batch_id),
        .button_batch_last(button_batch_last),
        .button_in_valid(button_in_valid),
        .button_in_ready(button_in_ready),
        .knob_states(knob_states),
        .knob_dirs(knob_dirs),
        .knob_pressed(knob_pressed),
        .knob_batch_id(knob_batch_id),
        .knob_batch_last(knob_batch_last),
        .knob_in_valid(knob_in_valid),
        .knob_in_ready(knob_in_ready),
        .handler_button_states(handler_button_states),
        .button_out_valid(button_out_valid),
        .button_out_ready(button_out_ready),
        .context_mode(context_mode),
        .context_fine_adjust(context_fine_adjust),
        .context_edit_enable(context_edit_enable),
        .context_edit_target(context_edit_target),
        .context_clear_wave_progress(context_clear_wave_progress),
        .context_valid(context_valid),
        .context_ready(context_ready),
        .handler_knob_states(handler_knob_states),
        .handler_knob_dirs(handler_knob_dirs),
        .handler_knob_pressed(handler_knob_pressed),
        .knob_out_valid(knob_out_valid),
        .knob_out_ready(knob_out_ready),
        .mode(mode),
        .fine_adjust(fine_adjust),
        .edit_enable(edit_enable),
        .edit_target(edit_target),
        .clear_wave_progress(clear_wave_progress),
        .frame_done_valid(frame_done_valid),
        .frame_done_ready(frame_done_ready),
        .protocol_error(protocol_error)
    );

    button_event_handler button_event_handler_u (
        .clk_sys(clk_sys),
        .rst_n(rst_n),
        .button_states(handler_button_states),
        .in_valid(button_out_valid),
        .in_ready(button_out_ready),
        .button_pressed_event(button_pressed_event),
        .button_released_event(button_released_event),
        .button_held(button_held),
        .out_valid(button_event_valid),
        .out_ready(button_event_ready)
    );

    ui_control_state ui_control_state_u (
        .clk_sys(clk_sys),
        .rst_n(rst_n),
        .button_pressed_event(button_pressed_event),
        .button_released_event(button_released_event),
        .button_held(button_held),
        .in_valid(button_event_valid),
        .in_ready(button_event_ready),
        .mode(context_mode),
        .fine_adjust(context_fine_adjust),
        .edit_enable(context_edit_enable),
        .edit_target(context_edit_target),
        .clear_wave_progress(context_clear_wave_progress),
        .context_valid(context_valid),
        .context_ready(context_ready)
    );

    knob_event_handler knob_event_handler_u (
        .clk_sys(clk_sys),
        .rst_n(rst_n),
        .scan_tick_up(scan_tick_up),
        .knob_states(handler_knob_states),
        .knob_dirs(handler_knob_dirs),
        .knob_pressed(handler_knob_pressed),
        .knob_delta(knob_delta),
        .knob_pressed_event(knob_pressed_event),
        .in_valid(knob_out_valid),
        .in_ready(knob_out_ready),
        .out_valid(knob_event_valid),
        .out_ready(knob_event_ready)
    );

    knob_parameter_controller #(
        .WAVE_SELECT_STEPS(WAVE_SELECT_STEPS)
    ) knob_parameter_controller_u (
        .clk_sys(clk_sys),
        .rst_n(rst_n),
        .knob_delta(knob_delta),
        .knob_pressed_event(knob_pressed_event),
        .mode(mode),
        .fine_adjust(fine_adjust),
        .edit_enable(edit_enable),
        .edit_target(edit_target),
        .clear_wave_progress(clear_wave_progress),
        .frame_done_valid(frame_done_valid),
        .frame_done_ready(frame_done_ready),
        .configuration_error(configuration_error),
        .in_valid(knob_event_valid),
        .in_ready(knob_event_ready),
        .wave_progress(),
        .wavetable_0(bank_wavetable_0),
        .wavetable_1(bank_wavetable_1),
        .interp_percent(bank_interp_percent),
        .phase_degrees(bank_phase_degrees),
        .attack_ms(bank_attack_ms),
        .decay_ms(bank_decay_ms),
        .sustain_percent(bank_sustain_percent),
        .release_ms(bank_release_ms),
        .master_percent(bank_master_percent),
        .reverb_mix_percent(bank_reverb_mix_percent),
        .delay_mix_percent(bank_delay_mix_percent),
        .distortion_mix_percent(bank_distortion_mix_percent),
        .chorus_mix_percent(bank_chorus_mix_percent),
        .parameter_valid(parameter_valid),
        .parameter_ready(parameter_ready)
    );

    ui_parameter_encoder #(
        .SMP_TICK_FREQ(SMP_TICK_FREQ)
    ) ui_parameter_encoder_u (
        .clk_sys(clk_sys),
        .rst_n(rst_n),
        .wavetable_0(bank_wavetable_0),
        .wavetable_1(bank_wavetable_1),
        .interp_percent(bank_interp_percent),
        .phase_degrees(bank_phase_degrees),
        .attack_ms(bank_attack_ms),
        .decay_ms(bank_decay_ms),
        .sustain_percent(bank_sustain_percent),
        .release_ms(bank_release_ms),
        .master_percent(bank_master_percent),
        .reverb_mix_percent(bank_reverb_mix_percent),
        .delay_mix_percent(bank_delay_mix_percent),
        .distortion_mix_percent(bank_distortion_mix_percent),
        .chorus_mix_percent(bank_chorus_mix_percent),
        .in_valid(parameter_valid),
        .in_ready(parameter_ready),
        .encoded_wavetable_0(wavetable_0),
        .encoded_wavetable_1(wavetable_1),
        .wavetable_interp(wavetable_interp),
        .init_phase(init_phase),
        .attack_ticks(attack_ticks),
        .decay_ticks(decay_ticks),
        .sustain_level(sustain_level),
        .release_ticks(release_ticks),
        .master_volume(master_volume),
        .reverb_mix(reverb_mix),
        .delay_mix(delay_mix),
        .distortion_mix(distortion_mix),
        .chorus_mix(chorus_mix),
        .out_valid(out_valid),
        .out_ready(out_ready)
    );

endmodule
