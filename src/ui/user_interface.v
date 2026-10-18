/**
 * 用户交互顶层：处理琴键、按钮和旋钮，向音频模块输出音符及音色参数。
 * 输入一次接收整组键盘、压力、按钮和旋钮数据；接收条件为 in_valid && in_ready。
 * 输出由 smp_tick_up 启动更新，out_valid && out_ready 时整组交付一次。
 * 等待接收时保持 valid 和数据不变；rst_n 接系统的 rst_sys_n。
 * NOTE: 相对 S1，ADR 改为 20 位采样周期数，新增总音量和四种效果干湿比。
 * NOTE: 新增 button_states、smp_tick_up 和错误指示，详见交接 README。
 * NOTE: 键盘与参数各取采样前已完成的结果，不保证同一输入同时生效。
 * TODO: 弯音尚未实现；note_busy 的更新规则待音频负责人确认。
 */
module user_interface
#(
    parameter KEY_NUM = 24,  // 琴键数量，1～24，按 C4 起连续编号
    parameter KNOB_NUM = 8,  // 旋钮数量；完整 UI 当前使用 8 个
    parameter BEND_NUM = 1,  // 弯音轮数量，当前保留 1 路接口
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
    input [15:0] bend_value [BEND_NUM-1:0],
    input [MAX_POLYPHONY-1:0] note_busy,
    output [MAX_POLYPHONY-1:0] note_on,
    output [MAX_POLYPHONY-1:0] note_off,
    output [31:0] note_freq [MAX_POLYPHONY-1:0],
    output [15:0] note_velocity [MAX_POLYPHONY-1:0],
    output [3:0] wavetable_0 [CHANNEL_NUM-1:0],
    output [3:0] wavetable_1 [CHANNEL_NUM-1:0],
    output [15:0] wavetable_interp [CHANNEL_NUM-1:0],
    output [15:0] init_phase [CHANNEL_NUM-1:0],
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
    output [15:0] master_volume,
    output [15:0] reverb_mix,
    output [15:0] delay_mix,
    output [15:0] distortion_mix,
    output [15:0] chorus_mix,
    output configuration_error,
    output sample_overrun
);
    localparam STATE_WAIT_COMBINED_FRAME = 1'b0;
    localparam STATE_DELIVER_FRAME_TO_ALL_SOURCES = 1'b1;
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
    reg [15:0] pressure_frame_r [KEY_NUM-1:0];
    wire keyboard_input_valid;
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
    wire [15:0] pipeline_init_phase [0:0];
    reg [15:0] latest_init_phase_r;
    reg [15:0] output_init_phase_r;
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
    reg [15:0] latest_master_volume_r;
    reg [15:0] output_master_volume_r;
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

    assign configuration_error = pipeline_configuration_error || pipeline_protocol_error ||
        (CHANNEL_NUM != 1) || (KNOB_NUM != 8) || (BEND_NUM != 1) || (KEY_NUM < 1) || (KEY_NUM > 24) ||
        (SMP_TICK_FREQ < 1000) || (SMP_TICK_FREQ > 209715) ||
        (MAX_POLYPHONY < 1) || (VELOCITY_SLEW_STEP == 16'd0);
    assign input_frame_available = !configuration_error && (current_state == STATE_WAIT_COMBINED_FRAME);
    assign in_ready = rst_n && input_frame_available;
    assign button_valid = rst_n && (current_state == STATE_DELIVER_FRAME_TO_ALL_SOURCES) && !button_delivered_r;
    assign knob_valid = rst_n && (current_state == STATE_DELIVER_FRAME_TO_ALL_SOURCES) && !knob_delivered_r;
    assign keyboard_input_valid = rst_n && (current_state == STATE_DELIVER_FRAME_TO_ALL_SOURCES) && !keyboard_delivered_r;
    // out_valid_r 与键盘有效状态均异步清零；不重复引入复位组合路径。
    assign out_valid = !configuration_error && out_valid_r && keyboard_audio_valid;
    assign audio_accept = out_valid && out_ready;
    assign sample_overrun = sample_overrun_r || keyboard_overrun;
    keyboard_note_pipeline #(
        .KEY_NUM(KEY_NUM), .MAX_POLYPHONY(MAX_POLYPHONY), .VELOCITY_SLEW_STEP(VELOCITY_SLEW_STEP)
    ) keyboard_note_pipeline_u (
        .clk_sys(clk_sys), .rst_n(rst_n), .scan_tick_up(scan_tick_up),
        .smp_tick_up(smp_tick_up && !configuration_error),
        .key_states(key_frame_r), .key_velocity(pressure_frame_r), .note_busy(note_busy),
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
            assign init_phase[channel_index] = (channel_index == 0) ? output_init_phase_r : 16'd0;
            assign attack_ticks[channel_index] = (channel_index == 0) ? output_attack_ticks_r : 20'd0;
            assign decay_ticks[channel_index] = (channel_index == 0) ? output_decay_ticks_r : 20'd0;
            assign sustain_level[channel_index] = (channel_index == 0) ? output_sustain_level_r : 16'd0;
            assign release_ticks[channel_index] = (channel_index == 0) ? output_release_ticks_r : 20'd0;
        end
    endgenerate
    assign master_volume = output_master_volume_r;
    assign reverb_mix = output_reverb_mix_r;
    assign delay_mix = output_delay_mix_r;
    assign distortion_mix = output_distortion_mix_r;
    assign chorus_mix = output_chorus_mix_r;
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
        .out_valid(pipeline_valid),
        .out_ready(1'b1),
        .protocol_error(pipeline_protocol_error),
        .configuration_error(pipeline_configuration_error),
        .wavetable_0(pipeline_wavetable_0),
        .wavetable_1(pipeline_wavetable_1),
        .wavetable_interp(pipeline_wavetable_interp),
        .init_phase(pipeline_init_phase),
        .attack_ticks(pipeline_attack_ticks),
        .decay_ticks(pipeline_decay_ticks),
        .sustain_level(pipeline_sustain_level),
        .release_ticks(pipeline_release_ticks),
        .master_volume(pipeline_master_volume),
        .reverb_mix(pipeline_reverb_mix),
        .delay_mix(pipeline_delay_mix),
        .distortion_mix(pipeline_distortion_mix),
        .chorus_mix(pipeline_chorus_mix)
    );

    localparam [3:0] DEFAULT_WAVETABLE_0 = 4'd0;
    localparam [3:0] DEFAULT_WAVETABLE_1 = 4'd1;
    localparam [15:0] DEFAULT_WAVETABLE_INTERP = 16'd0;
    localparam [15:0] DEFAULT_INIT_PHASE = 16'd0;
    localparam [19:0] DEFAULT_ATTACK_TICKS = ((64'd5 * SMP_TICK_FREQ + 64'd500) / 64'd1000);
    localparam [19:0] DEFAULT_DECAY_TICKS = ((64'd150 * SMP_TICK_FREQ + 64'd500) / 64'd1000);
    localparam [15:0] DEFAULT_SUSTAIN_LEVEL = 16'd45875;
    localparam [19:0] DEFAULT_RELEASE_TICKS = ((64'd200 * SMP_TICK_FREQ + 64'd500) / 64'd1000);
    localparam [15:0] DEFAULT_MASTER_VOLUME = 16'd19661;
    localparam [15:0] DEFAULT_REVERB_MIX = 16'd0;
    localparam [15:0] DEFAULT_DELAY_MIX = 16'd0;
    localparam [15:0] DEFAULT_DISTORTION_MIX = 16'd0;
    localparam [15:0] DEFAULT_CHORUS_MIX = 16'd0;
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
            latest_init_phase_r <= DEFAULT_INIT_PHASE;
            output_init_phase_r <= DEFAULT_INIT_PHASE;
            latest_attack_ticks_r <= DEFAULT_ATTACK_TICKS;
            output_attack_ticks_r <= DEFAULT_ATTACK_TICKS;
            latest_decay_ticks_r <= DEFAULT_DECAY_TICKS;
            output_decay_ticks_r <= DEFAULT_DECAY_TICKS;
            latest_sustain_level_r <= DEFAULT_SUSTAIN_LEVEL;
            output_sustain_level_r <= DEFAULT_SUSTAIN_LEVEL;
            latest_release_ticks_r <= DEFAULT_RELEASE_TICKS;
            output_release_ticks_r <= DEFAULT_RELEASE_TICKS;
            latest_master_volume_r <= DEFAULT_MASTER_VOLUME;
            output_master_volume_r <= DEFAULT_MASTER_VOLUME;
            latest_reverb_mix_r <= DEFAULT_REVERB_MIX;
            output_reverb_mix_r <= DEFAULT_REVERB_MIX;
            latest_delay_mix_r <= DEFAULT_DELAY_MIX;
            output_delay_mix_r <= DEFAULT_DELAY_MIX;
            latest_distortion_mix_r <= DEFAULT_DISTORTION_MIX;
            output_distortion_mix_r <= DEFAULT_DISTORTION_MIX;
            latest_chorus_mix_r <= DEFAULT_CHORUS_MIX;
            output_chorus_mix_r <= DEFAULT_CHORUS_MIX;
        end
        else
        begin
            if (pipeline_valid)
            begin
                latest_wavetable_0_r <= pipeline_wavetable_0[0];
                latest_wavetable_1_r <= pipeline_wavetable_1[0];
                latest_wavetable_interp_r <= pipeline_wavetable_interp[0];
                latest_init_phase_r <= pipeline_init_phase[0];
                latest_attack_ticks_r <= pipeline_attack_ticks[0];
                latest_decay_ticks_r <= pipeline_decay_ticks[0];
                latest_sustain_level_r <= pipeline_sustain_level[0];
                latest_release_ticks_r <= pipeline_release_ticks[0];
                latest_master_volume_r <= pipeline_master_volume;
                latest_reverb_mix_r <= pipeline_reverb_mix;
                latest_delay_mix_r <= pipeline_delay_mix;
                latest_distortion_mix_r <= pipeline_distortion_mix;
                latest_chorus_mix_r <= pipeline_chorus_mix;
            end
            if (audio_accept) out_valid_r <= 1'b0;
            if (smp_tick_up && !configuration_error)
            begin
                if (keyboard_sample_ready)
                begin
                    out_valid_r <= 1'b1;
                    output_wavetable_0_r <= latest_wavetable_0_r;
                    output_wavetable_1_r <= latest_wavetable_1_r;
                    output_wavetable_interp_r <= latest_wavetable_interp_r;
                    output_init_phase_r <= latest_init_phase_r;
                    output_attack_ticks_r <= latest_attack_ticks_r;
                    output_decay_ticks_r <= latest_decay_ticks_r;
                    output_sustain_level_r <= latest_sustain_level_r;
                    output_release_ticks_r <= latest_release_ticks_r;
                    output_master_volume_r <= latest_master_volume_r;
                    output_reverb_mix_r <= latest_reverb_mix_r;
                    output_delay_mix_r <= latest_delay_mix_r;
                    output_distortion_mix_r <= latest_distortion_mix_r;
                    output_chorus_mix_r <= latest_chorus_mix_r;
                end
                else sample_overrun_r <= 1'b1;
            end
        end
    end
endmodule
