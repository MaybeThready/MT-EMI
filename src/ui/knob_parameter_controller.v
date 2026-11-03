/**
 * 2026-10-31：两路增益统一UQ1.15，默认1.0（8000）；音色只保存balance，不保存master。
 * 高级音效页 K1/K2 调专属参数，K3 调演奏页共用的干湿比，K4 调该效果器的增益补偿。
 * v5 版本修改：音色先暂存并准备分组装载标记，下一拍握手时整组生效。
 * knob_delta: 每路 -1/0/+1 步；mode/fine_adjust: 本次使用的模式及微调开关。
 * 两路增益直接保存16位UQ1.15，其余参数按百分比、毫秒保存；按下旋钮恢复默认，优先于同次转动。
 * frame_done_valid: 本次旋钮已处理完成，即使没有修改参数也返回确认。
 * parameter_valid: 有一整组参数可读取；等待时保持，后续修改留到下一组输出。
 * WAVE_SELECT_STEPS: 换一张波形需累计的步数，合法范围 1～32767。
 * TODO: 默认值 0 表示未配置，会阻止正常工作；产品取值待定。
 */
module knob_parameter_controller
#(
    parameter [15:0] REVERB_FEEDBACK_DEFAULT = 16'd45056,  // UQ0.16，DEFAULT默认/MIN下限/MAX上限/STEP每格步进
    parameter [15:0] REVERB_FEEDBACK_MIN = 16'd0,  // UQ0.16，DEFAULT默认/MIN下限/MAX上限/STEP每格步进
    parameter [15:0] REVERB_FEEDBACK_MAX = 16'd61440,  // UQ0.16，DEFAULT默认/MIN下限/MAX上限/STEP每格步进
    parameter [15:0] REVERB_FEEDBACK_STEP = 16'd1024,  // UQ0.16，DEFAULT默认/MIN下限/MAX上限/STEP每格步进
    parameter [15:0] REVERB_DAMPING_DEFAULT = 16'd10240,  // UQ0.16，DEFAULT默认/MIN下限/MAX上限/STEP每格步进
    parameter [15:0] REVERB_DAMPING_MIN = 16'd0,  // UQ0.16，DEFAULT默认/MIN下限/MAX上限/STEP每格步进
    parameter [15:0] REVERB_DAMPING_MAX = 16'd61440,  // UQ0.16，DEFAULT默认/MIN下限/MAX上限/STEP每格步进
    parameter [15:0] REVERB_DAMPING_STEP = 16'd1024,  // UQ0.16，DEFAULT默认/MIN下限/MAX上限/STEP每格步进
    parameter [15:0] DELAY_TIME_DEFAULT = 16'd12000,  // 采样周期数，DEFAULT默认/MIN下限/MAX上限/STEP每格步进
    parameter [15:0] DELAY_TIME_MIN = 16'd1,  // 采样周期数，DEFAULT默认/MIN下限/MAX上限/STEP每格步进
    parameter [15:0] DELAY_TIME_MAX = 16'd65535,  // 采样周期数，DEFAULT默认/MIN下限/MAX上限/STEP每格步进
    parameter [15:0] DELAY_TIME_STEP = 16'd480,  // 采样周期数，DEFAULT默认/MIN下限/MAX上限/STEP每格步进
    parameter [15:0] DELAY_FEEDBACK_DEFAULT = 16'd36864,  // UQ0.16，DEFAULT默认/MIN下限/MAX上限/STEP每格步进
    parameter [15:0] DELAY_FEEDBACK_MIN = 16'd0,  // UQ0.16，DEFAULT默认/MIN下限/MAX上限/STEP每格步进
    parameter [15:0] DELAY_FEEDBACK_MAX = 16'd61440,  // UQ0.16，DEFAULT默认/MIN下限/MAX上限/STEP每格步进
    parameter [15:0] DELAY_FEEDBACK_STEP = 16'd1024,  // UQ0.16，DEFAULT默认/MIN下限/MAX上限/STEP每格步进
    parameter [15:0] DISTORTION_GAIN_DEFAULT = 16'd4096,  // UQ4.12，DEFAULT默认/MIN下限/MAX上限/STEP每格步进
    parameter [15:0] DISTORTION_GAIN_MIN = 16'd4096,  // UQ4.12，DEFAULT默认/MIN下限/MAX上限/STEP每格步进
    parameter [15:0] DISTORTION_GAIN_MAX = 16'd61440,  // UQ4.12，DEFAULT默认/MIN下限/MAX上限/STEP每格步进
    parameter [15:0] DISTORTION_GAIN_STEP = 16'd256,  // UQ4.12，DEFAULT默认/MIN下限/MAX上限/STEP每格步进
    parameter [15:0] DISTORTION_TONE_DEFAULT = 16'd32768,  // UQ0.16，DEFAULT默认/MIN下限/MAX上限/STEP每格步进
    parameter [15:0] DISTORTION_TONE_MIN = 16'd0,  // UQ0.16，DEFAULT默认/MIN下限/MAX上限/STEP每格步进
    parameter [15:0] DISTORTION_TONE_MAX = 16'd65535,  // UQ0.16，DEFAULT默认/MIN下限/MAX上限/STEP每格步进
    parameter [15:0] DISTORTION_TONE_STEP = 16'd1024,  // UQ0.16，DEFAULT默认/MIN下限/MAX上限/STEP每格步进
    parameter [15:0] CHORUS_RATE_DEFAULT = 16'd16384,  // UQ2.14 Hz，DEFAULT默认/MIN下限/MAX上限/STEP每格步进
    parameter [15:0] CHORUS_RATE_MIN = 16'd0,  // UQ2.14 Hz，DEFAULT默认/MIN下限/MAX上限/STEP每格步进
    parameter [15:0] CHORUS_RATE_MAX = 16'd65535,  // UQ2.14 Hz，DEFAULT默认/MIN下限/MAX上限/STEP每格步进
    parameter [15:0] CHORUS_RATE_STEP = 16'd1024,  // UQ2.14 Hz，DEFAULT默认/MIN下限/MAX上限/STEP每格步进
    parameter [15:0] CHORUS_DEPTH_DEFAULT = 16'd24,  // 采样周期数，8位有效，DEFAULT默认/MIN下限/MAX上限/STEP每格步进
    parameter [15:0] CHORUS_DEPTH_MIN = 16'd0,  // 采样周期数，8位有效，DEFAULT默认/MIN下限/MAX上限/STEP每格步进
    parameter [15:0] CHORUS_DEPTH_MAX = 16'd255,  // 采样周期数，8位有效，DEFAULT默认/MIN下限/MAX上限/STEP每格步进
    parameter [15:0] CHORUS_DEPTH_STEP = 16'd1,  // 采样周期数，8位有效，DEFAULT默认/MIN下限/MAX上限/STEP每格步进
    parameter WAVE_SELECT_STEPS = 0  // 换一张波形所需步数；0 表示未配置
)(
    input clk_sys,
    input rst_n,
    input signed [1:0] knob_delta [7:0],
    input [7:0] knob_pressed_event,
    input [1:0] mode,
    input fine_adjust,
    input edit_enable,
    input edit_target,
    input clear_wave_progress,
    input [1:0] effect_select,
    input effect_reset,  // 随本批输入握手，恢复两项高级参数、干湿比和增益补偿
    input in_valid,
    output in_ready,
    output frame_done_valid,
    input frame_done_ready,
    output configuration_error,
    output signed [15:0] wave_progress,
    output [3:0] wavetable_0 [0:0],
    output [3:0] wavetable_1 [0:0],
    output [6:0] interp_percent [0:0],
    output [6:0] detune_percent [0:0],
    output [10:0] attack_ms [0:0],
    output [10:0] decay_ms [0:0],
    output [6:0] sustain_percent [0:0],
    output [12:0] release_ms [0:0],
    output [15:0] master_gain,
    output [15:0] balance_gain,  // 音色增益快照，UQ1.15，0000..FFFF；K4调节且随音色存取，独立于演奏总音量
    output [6:0] reverb_mix_percent,
    output [6:0] delay_mix_percent,
    output [6:0] distortion_mix_percent,
    output [6:0] chorus_mix_percent,
    output [63:0] make_up_gains,  // {合唱, 失真, 延迟, 混响}，各 UQ1.15
    output [127:0] advanced_parameters,  // 8个16位字，已采用音频编码；随parameter_valid保持
    input [127:0] preset_load_advanced,
    output [127:0] preset_current_advanced,
    input [63:0] preset_load_make_up,
    output [63:0] preset_current_make_up,
    output parameter_valid,
    input parameter_ready,
    // 已校验的整组音色；优先于下一次旋钮事件，总音量保持不变。
    // NOTE: 空闲时先准备一拍再给 ready；valid 和参数须保持到握手，握手沿整组生效。
    input preset_load_valid,
    output preset_load_ready,
    input [191:0] preset_load_parameters,
    input [15:0] preset_load_balance_gain,
    output [15:0] preset_current_balance_gain,
    output [191:0] preset_current_parameters,
    // NEW display-only current edit value and committed action notifications.
    // No ready: these outputs must never gate parameter/audio/storage logic.
    output [15:0] display_master_gain, // UQ1.15, current bank (not audio snapshot).
    output display_update,            // One cycle after applying an edit/load.
    output [21:0] display_activity_mask, // V2 parameter IDs0..21, include limits.
    output [21:0] display_reset_mask     // Same-value reset is still an event.
);
    reg [127:0] advanced_r, advanced_next, advanced_snapshot_r, advanced_previous;
    // 每个16位字段独立比较并寄存，下一拍汇总；避免128位比较生成长进位链。
    reg [7:0] advanced_changed_r;
    integer compare_index;
    reg [127:0] preset_advanced_sampled_r;
    reg [63:0] preset_make_up_sampled_r;
    reg [1:0] effect_select_captured;
    reg effect_reset_captured;
    integer effect_index;
    reg [31:0] effect_adjusted;
    assign advanced_parameters = advanced_snapshot_r;
    assign preset_current_advanced = advanced_r;
    function [15:0] effect_default;
        input integer index;
        begin
            case (index)
                0: effect_default = REVERB_FEEDBACK_DEFAULT;
                1: effect_default = REVERB_DAMPING_DEFAULT;
                2: effect_default = DELAY_TIME_DEFAULT;
                3: effect_default = DELAY_FEEDBACK_DEFAULT;
                4: effect_default = DISTORTION_GAIN_DEFAULT;
                5: effect_default = DISTORTION_TONE_DEFAULT;
                6: effect_default = CHORUS_RATE_DEFAULT;
                7: effect_default = CHORUS_DEPTH_DEFAULT;
                default: effect_default = 16'd0;
            endcase
        end
    endfunction
    function [15:0] effect_min;
        input integer index;
        begin
            case (index)
                0: effect_min = REVERB_FEEDBACK_MIN;
                1: effect_min = REVERB_DAMPING_MIN;
                2: effect_min = DELAY_TIME_MIN;
                3: effect_min = DELAY_FEEDBACK_MIN;
                4: effect_min = DISTORTION_GAIN_MIN;
                5: effect_min = DISTORTION_TONE_MIN;
                6: effect_min = CHORUS_RATE_MIN;
                7: effect_min = CHORUS_DEPTH_MIN;
                default: effect_min = 16'd0;
            endcase
        end
    endfunction
    function [15:0] effect_max;
        input integer index;
        begin
            case (index)
                0: effect_max = REVERB_FEEDBACK_MAX;
                1: effect_max = REVERB_DAMPING_MAX;
                2: effect_max = DELAY_TIME_MAX;
                3: effect_max = DELAY_FEEDBACK_MAX;
                4: effect_max = DISTORTION_GAIN_MAX;
                5: effect_max = DISTORTION_TONE_MAX;
                6: effect_max = CHORUS_RATE_MAX;
                7: effect_max = CHORUS_DEPTH_MAX;
                default: effect_max = 16'd0;
            endcase
        end
    endfunction
    function [15:0] effect_step;
        input integer index;
        begin
            case (index)
                0: effect_step = REVERB_FEEDBACK_STEP;
                1: effect_step = REVERB_DAMPING_STEP;
                2: effect_step = DELAY_TIME_STEP;
                3: effect_step = DELAY_FEEDBACK_STEP;
                4: effect_step = DISTORTION_GAIN_STEP;
                5: effect_step = DISTORTION_TONE_STEP;
                6: effect_step = CHORUS_RATE_STEP;
                7: effect_step = CHORUS_DEPTH_STEP;
                default: effect_step = 16'd0;
            endcase
        end
    endfunction
    // 冻结数据传输属性；握手后不再使用实时输入。
    integer capture_index;
    reg signed [1:0] knob_delta_captured [7:0];
    reg [7:0] knob_pressed_event_captured;
    reg [1:0] mode_captured;
    reg  fine_adjust_captured;
    reg  edit_enable_captured;
    reg  edit_target_captured;
    reg  clear_wave_progress_captured;
    reg [3:0] wavetable_0_previous;
    reg [3:0] wavetable_1_previous;
    reg [6:0] interp_percent_previous;
    reg [6:0] detune_percent_previous;
    reg [10:0] attack_ms_previous;
    reg [10:0] decay_ms_previous;
    reg [6:0] sustain_percent_previous;
    reg [12:0] release_ms_previous;
    reg [15:0] master_gain_previous;
    reg [6:0] reverb_mix_percent_previous;
    reg [6:0] delay_mix_percent_previous;
    reg [6:0] distortion_mix_percent_previous;
    reg [6:0] chorus_mix_percent_previous;
    // 计算之后先分组比较再汇总更新；完成确认比旧版多一拍，握手协议不变。
    localparam STATE_WAIT_EVENT_FRAME = 3'd0;
    localparam STATE_CALCULATE_FRAME = 3'd1;
    localparam STATE_MARK_PARAMETERS_DIRTY = 3'd2;
    localparam STATE_WAIT_COMPLETION_ACCEPT = 3'd3;
    localparam STATE_COMPARE_PARAMETERS = 3'd4;
    // 余量范围为 -(steps-1)～+(steps-1)，包含符号位；
    // 候选结果再扩一位，保证达到阈值时的加法不溢出。
    localparam WAVE_PROGRESS_WIDTH = (WAVE_SELECT_STEPS > 1) ? $clog2(WAVE_SELECT_STEPS) + 1 : 2;
    wire [2:0] current_state;
    reg [2:0] next_state;
    reg signed [WAVE_PROGRESS_WIDTH-1:0] wave_progress_r;
    reg signed [WAVE_PROGRESS_WIDTH-1:0] wave_progress_next;
    reg signed [WAVE_PROGRESS_WIDTH:0] wave_sum;
    reg snapshot_valid_r;
    reg snapshot_dirty_r;
    // 仅本地装载标记驱动整组快照；不能用上一拍 ready 代替当前握手。
    reg snapshot_load_pending_r /* synthesis syn_preserve = 1 */;
    // 数据逐拍暂存；只有准备完成后的握手沿才更新可见参数。
    reg [191:0] preset_parameters_sampled_r;
    reg [15:0] preset_balance_sampled_r;
    reg [15:0] balance_gain_r;
    reg [15:0] balance_gain_next;
    reg [15:0] balance_gain_previous;
    reg [63:0] make_up_r, make_up_next, make_up_snapshot_r, make_up_previous;
    reg [31:0] make_up_adjusted;
    assign make_up_gains = make_up_snapshot_r;
    assign preset_current_make_up = make_up_r;
    wire [31:0] balance_gain_adjusted;
    assign balance_gain_adjusted = adjust_value({16'd0, balance_gain_r}, knob_delta_captured[3],
        fine_adjust_captured ? 32'd328 : 32'd1638, 32'd0, 32'd65535);
    reg [15:0] balance_gain_snapshot_r;
    assign balance_gain = balance_gain_snapshot_r;
    assign preset_current_balance_gain = balance_gain_r;
    // 三组同拍准备、同拍装载，分别驱动波形／相位、ADSR、效果比例。
    reg preset_wave_load_pending_r /* synthesis syn_preserve = 1 */;
    reg preset_envelope_load_pending_r /* synthesis syn_preserve = 1 */;
    reg preset_effect_load_pending_r /* synthesis syn_preserve = 1 */;
    wire bank_changed;
    // 先限幅到字段合法范围，再明确截取结果位宽。
    wire [31:0] master_gain_adjusted;
    assign master_gain_adjusted = adjust_value({16'd0, master_gain_r}, knob_delta_captured[2],
        fine_adjust_captured ? 32'd328 : 32'd1638, 32'd0, 32'd65535);
    wire [31:0] interp_percent_adjusted;
    assign interp_percent_adjusted = adjust_value(interp_percent_r, knob_delta_captured[1],
        fine_adjust_captured ? 32'd1 : 32'd5, 32'd0, 32'd100);
    wire [31:0] detune_percent_adjusted;
    assign detune_percent_adjusted = adjust_value(detune_percent_r, knob_delta_captured[1],
        fine_adjust_captured ? 32'd1 : 32'd5, 32'd0, 32'd100);
    wire [31:0] attack_ms_adjusted;
    assign attack_ms_adjusted = adjust_value(attack_ms_r, knob_delta_captured[4],
        fine_adjust_captured ? 32'd1 : 32'd10, 32'd1, 32'd2000);
    wire [31:0] decay_ms_adjusted;
    assign decay_ms_adjusted = adjust_value(decay_ms_r, knob_delta_captured[5],
        fine_adjust_captured ? 32'd1 : 32'd10, 32'd1, 32'd2000);
    wire [31:0] sustain_percent_adjusted;
    assign sustain_percent_adjusted = adjust_value(sustain_percent_r, knob_delta_captured[6],
        fine_adjust_captured ? 32'd1 : 32'd5, 32'd0, 32'd100);
    wire [31:0] release_ms_adjusted;
    assign release_ms_adjusted = adjust_value(release_ms_r, knob_delta_captured[7],
        fine_adjust_captured ? 32'd1 : 32'd50, 32'd0, 32'd5000);
    wire [31:0] reverb_mix_percent_adjusted;
    assign reverb_mix_percent_adjusted = adjust_value(reverb_mix_percent_r, knob_delta_captured[4],
        fine_adjust_captured ? 32'd1 : 32'd5, 32'd0, 32'd100);
    wire [31:0] delay_mix_percent_adjusted;
    assign delay_mix_percent_adjusted = adjust_value(delay_mix_percent_r, knob_delta_captured[5],
        fine_adjust_captured ? 32'd1 : 32'd5, 32'd0, 32'd100);
    wire [31:0] distortion_mix_percent_adjusted;
    assign distortion_mix_percent_adjusted = adjust_value(distortion_mix_percent_r, knob_delta_captured[6],
        fine_adjust_captured ? 32'd1 : 32'd5, 32'd0, 32'd100);
    wire [31:0] chorus_mix_percent_adjusted;
    assign chorus_mix_percent_adjusted = adjust_value(chorus_mix_percent_r, knob_delta_captured[7],
        fine_adjust_captured ? 32'd1 : 32'd5, 32'd0, 32'd100);

    reg [3:0] wavetable_0_r;
    reg [3:0] wavetable_0_next;
    reg [3:0] wavetable_0_snapshot_r;
    assign wavetable_0[0] = wavetable_0_snapshot_r;
    reg [3:0] wavetable_1_r;
    reg [3:0] wavetable_1_next;
    reg [3:0] wavetable_1_snapshot_r;
    assign wavetable_1[0] = wavetable_1_snapshot_r;
    reg [6:0] interp_percent_r;
    reg [6:0] interp_percent_next;
    reg [6:0] interp_percent_snapshot_r;
    assign interp_percent[0] = interp_percent_snapshot_r;
    reg [6:0] detune_percent_r;
    reg [6:0] detune_percent_next;
    reg [6:0] detune_percent_snapshot_r;
    assign detune_percent[0] = detune_percent_snapshot_r;
    reg [10:0] attack_ms_r;
    reg [10:0] attack_ms_next;
    reg [10:0] attack_ms_snapshot_r;
    assign attack_ms[0] = attack_ms_snapshot_r;
    reg [10:0] decay_ms_r;
    reg [10:0] decay_ms_next;
    reg [10:0] decay_ms_snapshot_r;
    assign decay_ms[0] = decay_ms_snapshot_r;
    reg [6:0] sustain_percent_r;
    reg [6:0] sustain_percent_next;
    reg [6:0] sustain_percent_snapshot_r;
    assign sustain_percent[0] = sustain_percent_snapshot_r;
    reg [12:0] release_ms_r;
    reg [12:0] release_ms_next;
    reg [12:0] release_ms_snapshot_r;
    assign release_ms[0] = release_ms_snapshot_r;
    reg [15:0] master_gain_r;
    reg [15:0] master_gain_next;
    reg [15:0] master_gain_snapshot_r;
    assign master_gain = master_gain_snapshot_r;
    reg [6:0] reverb_mix_percent_r;
    reg [6:0] reverb_mix_percent_next;
    reg [6:0] reverb_mix_percent_snapshot_r;
    assign reverb_mix_percent = reverb_mix_percent_snapshot_r;
    reg [6:0] delay_mix_percent_r;
    reg [6:0] delay_mix_percent_next;
    reg [6:0] delay_mix_percent_snapshot_r;
    assign delay_mix_percent = delay_mix_percent_snapshot_r;
    reg [6:0] distortion_mix_percent_r;
    reg [6:0] distortion_mix_percent_next;
    reg [6:0] distortion_mix_percent_snapshot_r;
    assign distortion_mix_percent = distortion_mix_percent_snapshot_r;
    reg [6:0] chorus_mix_percent_r;
    reg [6:0] chorus_mix_percent_next;
    reg [6:0] chorus_mix_percent_snapshot_r;
    assign chorus_mix_percent = chorus_mix_percent_snapshot_r;

    assign preset_current_parameters = {
        {9'd0, chorus_mix_percent_r},
        {9'd0, distortion_mix_percent_r},
        {9'd0, delay_mix_percent_r},
        {9'd0, reverb_mix_percent_r},
        {3'd0, release_ms_r},
        {9'd0, sustain_percent_r},
        {5'd0, decay_ms_r},
        {5'd0, attack_ms_r},
        {9'd0, detune_percent_r},
        {9'd0, interp_percent_r},
        {12'd0, wavetable_1_r},
        {12'd0, wavetable_0_r}
    };

    assign configuration_error = (WAVE_SELECT_STEPS < 1) || (WAVE_SELECT_STEPS > 32767);
    wire preset_load_request;
    wire event_accept_enable;
    wire preset_accept_enable;
    // 内部状态和数据已有异步复位；带复位保护的 ready 只用于外部握手。
    assign preset_accept_enable = !configuration_error && (current_state == STATE_WAIT_EVENT_FRAME)
        && !preset_wave_load_pending_r;
    assign event_accept_enable = preset_accept_enable && !preset_load_request;
    assign in_ready = rst_n && event_accept_enable;
    // 未使用音色功能时，preset_load_valid 必须接 0，不允许悬空。
    assign preset_load_request = preset_load_valid;
    assign preset_load_ready = rst_n && preset_wave_load_pending_r;
    assign frame_done_valid = rst_n && (current_state == STATE_WAIT_COMPLETION_ACCEPT);
    assign parameter_valid = rst_n && snapshot_valid_r;
    assign wave_progress = wave_progress_r;
    assign bank_changed = (|advanced_changed_r) ||
        (make_up_previous != make_up_r) ||
        (balance_gain_previous != balance_gain_r) ||
        (wavetable_0_previous != wavetable_0_r) ||
        (wavetable_1_previous != wavetable_1_r) ||
        (interp_percent_previous != interp_percent_r) ||
        (detune_percent_previous != detune_percent_r) ||
        (attack_ms_previous != attack_ms_r) ||
        (decay_ms_previous != decay_ms_r) ||
        (sustain_percent_previous != sustain_percent_r) ||
        (release_ms_previous != release_ms_r) ||
        (master_gain_previous != master_gain_r) ||
        (reverb_mix_percent_previous != reverb_mix_percent_r) ||
        (delay_mix_percent_previous != delay_mix_percent_r) ||
        (distortion_mix_percent_previous != distortion_mix_percent_r) ||
        (chorus_mix_percent_previous != chorus_mix_percent_r);

    fsm #(
        .W(3), .INITIAL_STATE(STATE_WAIT_EVENT_FRAME)
    ) fsm_u (
        .clk(clk_sys), .rst_n(rst_n), .stn(next_state), .stc(current_state)
    );
    always @(*)
    begin
        next_state = current_state;
        case (current_state)
            STATE_WAIT_EVENT_FRAME:
                if (in_valid && event_accept_enable) next_state = STATE_CALCULATE_FRAME;
            STATE_CALCULATE_FRAME: next_state = STATE_COMPARE_PARAMETERS;
            STATE_COMPARE_PARAMETERS: next_state = STATE_MARK_PARAMETERS_DIRTY;
            STATE_MARK_PARAMETERS_DIRTY: next_state = STATE_WAIT_COMPLETION_ACCEPT;
            STATE_WAIT_COMPLETION_ACCEPT:
                if (frame_done_ready) next_state = STATE_WAIT_EVENT_FRAME;
            default: next_state = STATE_WAIT_EVENT_FRAME;
        endcase
    end

    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
            advanced_changed_r <= 8'd0;
        else if (current_state == STATE_COMPARE_PARAMETERS)
        begin
            for (compare_index = 0; compare_index < 8; compare_index = compare_index + 1)
                advanced_changed_r[compare_index] <=
                    (advanced_previous[16*compare_index +: 16] != advanced_r[16*compare_index +: 16]);
        end
    end

    // 使用 32 位有符号中间值，避免减法在限幅前发生无符号回绕。
    // 此处为小范围整数运算，不直接套用 Q 格式运算模块。
    function [31:0] adjust_value;
        input [31:0] value;
        input signed [1:0] delta;
        input [31:0] step;
        input [31:0] minimum;
        input [31:0] maximum;
        reg signed [32:0] candidate;
        begin
            candidate = $signed({1'b0, value});
            if (delta == 2'sd1) candidate = candidate + $signed({1'b0, step});
            else if (delta == -2'sd1) candidate = candidate - $signed({1'b0, step});
            if (candidate < $signed({1'b0, minimum})) adjust_value = minimum;
            else if (candidate > $signed({1'b0, maximum})) adjust_value = maximum;
            else adjust_value = candidate[31:0];
        end
    endfunction

    always @(*)
    begin
        advanced_next = advanced_r;
        effect_adjusted = 32'd0;
        for (effect_index = 0; effect_index < 8; effect_index = effect_index + 1)
        begin
            if (mode_captured == 2'd2 && effect_select_captured == (effect_index / 2))
            begin
                if (effect_reset_captured || (edit_enable_captured && knob_pressed_event_captured[effect_index % 2]))
                    advanced_next[16*effect_index +: 16] = effect_default(effect_index);
                else if (edit_enable_captured)
                begin
                    effect_adjusted = adjust_value({16'd0, advanced_r[16*effect_index +: 16]},
                        knob_delta_captured[effect_index % 2], {16'd0, effect_step(effect_index)},
                        {16'd0, effect_min(effect_index)}, {16'd0, effect_max(effect_index)});
                    advanced_next[16*effect_index +: 16] = effect_adjusted[15:0];
                end
            end
        end
        wavetable_0_next = wavetable_0_r;
        wavetable_1_next = wavetable_1_r;
        interp_percent_next = interp_percent_r;
        detune_percent_next = detune_percent_r;
        attack_ms_next = attack_ms_r;
        decay_ms_next = decay_ms_r;
        sustain_percent_next = sustain_percent_r;
        release_ms_next = release_ms_r;
        master_gain_next = master_gain_r;
        balance_gain_next = balance_gain_r;
        make_up_next = make_up_r;
        make_up_adjusted = 32'd0;
        reverb_mix_percent_next = reverb_mix_percent_r;
        delay_mix_percent_next = delay_mix_percent_r;
        distortion_mix_percent_next = distortion_mix_percent_r;
        chorus_mix_percent_next = chorus_mix_percent_r;
        if (mode_captured == 2'd2 && effect_reset_captured)
        begin
            case (effect_select_captured)
                2'd0: reverb_mix_percent_next = 7'd0;
                2'd1: delay_mix_percent_next = 7'd0;
                2'd2: distortion_mix_percent_next = 7'd0;
                2'd3: chorus_mix_percent_next = 7'd0;
            endcase
        end
        if (mode_captured == 2'd2)
        begin
            if (effect_reset_captured || (edit_enable_captured && knob_pressed_event_captured[3]))
                make_up_next[16*effect_select_captured +: 16] = 16'h8000;
            else if (edit_enable_captured)
            begin
                make_up_adjusted = adjust_value(
                    {16'd0, make_up_r[16*effect_select_captured +: 16]}, knob_delta_captured[3],
                    fine_adjust_captured ? 32'd328 : 32'd1638, 32'd0, 32'd65535);
                make_up_next[16*effect_select_captured +: 16] = make_up_adjusted[15:0];
            end
            if (edit_enable_captured && !effect_reset_captured)
            begin
                case (effect_select_captured)
                    2'd0: reverb_mix_percent_next = knob_pressed_event_captured[2] ? 7'd0 :
                        adjust_value(reverb_mix_percent_r, knob_delta_captured[2],
                            fine_adjust_captured ? 32'd1 : 32'd5, 32'd0, 32'd100);
                    2'd1: delay_mix_percent_next = knob_pressed_event_captured[2] ? 7'd0 :
                        adjust_value(delay_mix_percent_r, knob_delta_captured[2],
                            fine_adjust_captured ? 32'd1 : 32'd5, 32'd0, 32'd100);
                    2'd2: distortion_mix_percent_next = knob_pressed_event_captured[2] ? 7'd0 :
                        adjust_value(distortion_mix_percent_r, knob_delta_captured[2],
                            fine_adjust_captured ? 32'd1 : 32'd5, 32'd0, 32'd100);
                    2'd3: chorus_mix_percent_next = knob_pressed_event_captured[2] ? 7'd0 :
                        adjust_value(chorus_mix_percent_r, knob_delta_captured[2],
                            fine_adjust_captured ? 32'd1 : 32'd5, 32'd0, 32'd100);
                endcase
            end
        end
        wave_progress_next = clear_wave_progress_captured ? '0 : wave_progress_r;
        wave_sum = $signed(wave_progress_next);
        if (edit_enable_captured && !edit_target_captured && ((mode_captured == 2'd0) || (mode_captured == 2'd1)))
        begin
            if (knob_pressed_event_captured[0])
            begin
                wave_progress_next = '0;
                if (mode_captured == 2'd0) wavetable_0_next = 4'd0;
                else wavetable_1_next = 4'd1;
            end
            else if ((knob_delta_captured[0] == 2'sd1) || (knob_delta_captured[0] == -2'sd1))
            begin
                wave_sum = wave_sum + $signed(knob_delta_captured[0]);
                if ((((mode_captured == 2'd0) ? wavetable_0_r : wavetable_1_r) == 4'd0 && wave_sum < 0) ||
                    (((mode_captured == 2'd0) ? wavetable_0_r : wavetable_1_r) == 4'd3 && wave_sum > 0))
                    wave_progress_next = '0;
                else if (wave_sum >= WAVE_SELECT_STEPS)
                begin
                    if (mode_captured == 2'd0) wavetable_0_next = wavetable_0_r + 4'd1;
                    else wavetable_1_next = wavetable_1_r + 4'd1;
                    wave_progress_next = '0;
                end
                else if (wave_sum <= -WAVE_SELECT_STEPS)
                begin
                    if (mode_captured == 2'd0) wavetable_0_next = wavetable_0_r - 4'd1;
                    else wavetable_1_next = wavetable_1_r - 4'd1;
                    wave_progress_next = '0;
                end
                else wave_progress_next = wave_sum[WAVE_PROGRESS_WIDTH-1:0];
            end
            // NOTE: 增益粗调1638（约0.05），微调328（约0.01），限幅0000..FFFF；按压恢复8000。
            // NOTE: K3为演奏总音量；K4为音色自身增益，保存时不包含K3。
            if (knob_pressed_event_captured[3]) balance_gain_next = 16'h8000;
            else balance_gain_next = balance_gain_adjusted[15:0];
            if (knob_pressed_event_captured[2]) master_gain_next = 16'h8000;
            else master_gain_next = master_gain_adjusted[15:0];
            if (mode_captured == 2'd0)
            begin
                if (knob_pressed_event_captured[1]) interp_percent_next = 7'd0;
                else interp_percent_next = interp_percent_adjusted[6:0];
            end
            if (mode_captured == 2'd1)
            begin
                if (knob_pressed_event_captured[1]) detune_percent_next = 7'd0;
                else detune_percent_next = detune_percent_adjusted[6:0];
            end
            if (mode_captured == 2'd0)
            begin
                if (knob_pressed_event_captured[4]) attack_ms_next = 11'd5;
                else attack_ms_next = attack_ms_adjusted[10:0];
            end
            if (mode_captured == 2'd0)
            begin
                if (knob_pressed_event_captured[5]) decay_ms_next = 11'd150;
                else decay_ms_next = decay_ms_adjusted[10:0];
            end
            if (mode_captured == 2'd0)
            begin
                if (knob_pressed_event_captured[6]) sustain_percent_next = 7'd70;
                else sustain_percent_next = sustain_percent_adjusted[6:0];
            end
            if (mode_captured == 2'd0)
            begin
                if (knob_pressed_event_captured[7]) release_ms_next = 13'd200;
                else release_ms_next = release_ms_adjusted[12:0];
            end
            if (mode_captured == 2'd1)
            begin
                if (knob_pressed_event_captured[4]) reverb_mix_percent_next = 7'd0;
                else reverb_mix_percent_next = reverb_mix_percent_adjusted[6:0];
            end
            if (mode_captured == 2'd1)
            begin
                if (knob_pressed_event_captured[5]) delay_mix_percent_next = 7'd0;
                else delay_mix_percent_next = delay_mix_percent_adjusted[6:0];
            end
            if (mode_captured == 2'd1)
            begin
                if (knob_pressed_event_captured[6]) distortion_mix_percent_next = 7'd0;
                else distortion_mix_percent_next = distortion_mix_percent_adjusted[6:0];
            end
            if (mode_captured == 2'd1)
            begin
                if (knob_pressed_event_captured[7]) chorus_mix_percent_next = 7'd0;
                else chorus_mix_percent_next = chorus_mix_percent_adjusted[6:0];
            end
        end
    end

    // 输入在背压期间必须保持：E0 准备并暂存，E1 ready=1 时握手并装载。
    // 上游无需等待 ready 才产生 valid；复位取消准备，E1 之前不改变当前参数。
    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            preset_parameters_sampled_r <= 192'd0;
            preset_balance_sampled_r <= 16'h8000;
            preset_advanced_sampled_r <= {CHORUS_DEPTH_DEFAULT, CHORUS_RATE_DEFAULT, DISTORTION_TONE_DEFAULT, DISTORTION_GAIN_DEFAULT, DELAY_FEEDBACK_DEFAULT, DELAY_TIME_DEFAULT, REVERB_DAMPING_DEFAULT, REVERB_FEEDBACK_DEFAULT};
            preset_make_up_sampled_r <= {4{16'h8000}};
            preset_wave_load_pending_r <= 1'b0;
            preset_envelope_load_pending_r <= 1'b0;
            preset_effect_load_pending_r <= 1'b0;
        end
        else
        begin
            // 这里不使用握手作为宽总线使能，避免把原长路径搬到暂存寄存器。
            preset_parameters_sampled_r <= preset_load_parameters;
            preset_balance_sampled_r <= preset_load_balance_gain;
            preset_advanced_sampled_r <= preset_load_advanced;
            preset_make_up_sampled_r <= preset_load_make_up;
            preset_wave_load_pending_r <= preset_load_request && preset_accept_enable;
            preset_envelope_load_pending_r <= preset_load_request && preset_accept_enable;
            preset_effect_load_pending_r <= preset_load_request && preset_accept_enable;
        end
    end

    // 快照空闲或刚被接收时，先预约装载；预约期间 valid 为零，避免重复交付。
    // ready 只影响这两个控制位，不再直接控制整组参数寄存器。
    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            snapshot_valid_r <= 1'b0;
            snapshot_load_pending_r <= 1'b0;
        end
        else if (snapshot_load_pending_r)
        begin
            snapshot_load_pending_r <= 1'b0;
            snapshot_valid_r <= 1'b1;
        end
        else if (!snapshot_valid_r || parameter_ready)
        begin
            snapshot_valid_r <= 1'b0;
            snapshot_load_pending_r <= snapshot_dirty_r;
        end
    end

    // 预约的下一拍捕获当时的参数；同拍发生的新编辑由 dirty 保留到下一组。
    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            wavetable_0_snapshot_r <= 4'd0;
            wavetable_1_snapshot_r <= 4'd1;
            interp_percent_snapshot_r <= 7'd0;
            detune_percent_snapshot_r <= 7'd0;
            attack_ms_snapshot_r <= 11'd5;
            decay_ms_snapshot_r <= 11'd150;
            sustain_percent_snapshot_r <= 7'd70;
            release_ms_snapshot_r <= 13'd200;
            master_gain_snapshot_r <= 16'h8000;
            balance_gain_snapshot_r <= 16'h8000;
            advanced_snapshot_r <= {CHORUS_DEPTH_DEFAULT, CHORUS_RATE_DEFAULT, DISTORTION_TONE_DEFAULT, DISTORTION_GAIN_DEFAULT, DELAY_FEEDBACK_DEFAULT, DELAY_TIME_DEFAULT, REVERB_DAMPING_DEFAULT, REVERB_FEEDBACK_DEFAULT};
            make_up_snapshot_r <= {4{16'h8000}};
            reverb_mix_percent_snapshot_r <= 7'd0;
            delay_mix_percent_snapshot_r <= 7'd0;
            distortion_mix_percent_snapshot_r <= 7'd0;
            chorus_mix_percent_snapshot_r <= 7'd0;
        end
        else if (snapshot_load_pending_r)
        begin
            wavetable_0_snapshot_r <= wavetable_0_r;
            wavetable_1_snapshot_r <= wavetable_1_r;
            interp_percent_snapshot_r <= interp_percent_r;
            detune_percent_snapshot_r <= detune_percent_r;
            attack_ms_snapshot_r <= attack_ms_r;
            decay_ms_snapshot_r <= decay_ms_r;
            sustain_percent_snapshot_r <= sustain_percent_r;
            release_ms_snapshot_r <= release_ms_r;
            master_gain_snapshot_r <= master_gain_r;
            balance_gain_snapshot_r <= balance_gain_r;
            advanced_snapshot_r <= advanced_r;
            make_up_snapshot_r <= make_up_r;
            reverb_mix_percent_snapshot_r <= reverb_mix_percent_r;
            delay_mix_percent_snapshot_r <= delay_mix_percent_r;
            distortion_mix_percent_snapshot_r <= distortion_mix_percent_r;
            chorus_mix_percent_snapshot_r <= chorus_mix_percent_r;
        end
    end

    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            wave_progress_r <= '0;
            snapshot_dirty_r <= 1'b1;
            wavetable_0_r <= 4'd0;
            wavetable_1_r <= 4'd1;
            interp_percent_r <= 7'd0;
            detune_percent_r <= 7'd0;
            attack_ms_r <= 11'd5;
            decay_ms_r <= 11'd150;
            sustain_percent_r <= 7'd70;
            release_ms_r <= 13'd200;
            master_gain_r <= 16'h8000;
            balance_gain_r <= 16'h8000;
            advanced_r <= {CHORUS_DEPTH_DEFAULT, CHORUS_RATE_DEFAULT, DISTORTION_TONE_DEFAULT, DISTORTION_GAIN_DEFAULT, DELAY_FEEDBACK_DEFAULT, DELAY_TIME_DEFAULT, REVERB_DAMPING_DEFAULT, REVERB_FEEDBACK_DEFAULT};
            make_up_r <= {4{16'h8000}};
            reverb_mix_percent_r <= 7'd0;
            delay_mix_percent_r <= 7'd0;
            distortion_mix_percent_r <= 7'd0;
            chorus_mix_percent_r <= 7'd0;
        end
        else
        begin
            // 装载时才清除更新标记；下方同拍编辑／音色装载重新置位，不能丢失。
            if (snapshot_load_pending_r)
                snapshot_dirty_r <= 1'b0;
            if (current_state == STATE_CALCULATE_FRAME)
            begin
                wave_progress_r <= wave_progress_next;
                wavetable_0_r <= wavetable_0_next;
                wavetable_1_r <= wavetable_1_next;
                interp_percent_r <= interp_percent_next;
                detune_percent_r <= detune_percent_next;
                attack_ms_r <= attack_ms_next;
                decay_ms_r <= decay_ms_next;
                sustain_percent_r <= sustain_percent_next;
                release_ms_r <= release_ms_next;
                master_gain_r <= master_gain_next;
                balance_gain_r <= balance_gain_next;
                advanced_r <= advanced_next;
                make_up_r <= make_up_next;
                reverb_mix_percent_r <= reverb_mix_percent_next;
                delay_mix_percent_r <= delay_mix_percent_next;
                distortion_mix_percent_r <= distortion_mix_percent_next;
                chorus_mix_percent_r <= chorus_mix_percent_next;
            end
            // 上游 valid 在 ready 到来前保持，因此本地标记与本拍握手一致。
            if (preset_wave_load_pending_r)
            begin
                wavetable_0_r <= preset_parameters_sampled_r[3:0];
                wavetable_1_r <= preset_parameters_sampled_r[19:16];
                interp_percent_r <= preset_parameters_sampled_r[38:32];
                detune_percent_r <= preset_parameters_sampled_r[63:48] > 16'd100 ?
                                    7'd100 : preset_parameters_sampled_r[54:48];
                wave_progress_r <= '0;
                snapshot_dirty_r <= 1'b1;
            end
            if (preset_envelope_load_pending_r)
            begin
                attack_ms_r <= preset_parameters_sampled_r[74:64];
                decay_ms_r <= preset_parameters_sampled_r[90:80];
                sustain_percent_r <= preset_parameters_sampled_r[102:96];
                release_ms_r <= preset_parameters_sampled_r[124:112];
            end
            if (preset_effect_load_pending_r)
            begin
                // 同组装载音色增益；master_gain_r 不在加载分支更新。
                balance_gain_r <= preset_balance_sampled_r;
                advanced_r <= preset_advanced_sampled_r;
                make_up_r <= preset_make_up_sampled_r;
                reverb_mix_percent_r <= preset_parameters_sampled_r[134:128];
                delay_mix_percent_r <= preset_parameters_sampled_r[150:144];
                distortion_mix_percent_r <= preset_parameters_sampled_r[166:160];
                chorus_mix_percent_r <= preset_parameters_sampled_r[182:176];
            end
            if ((current_state == STATE_MARK_PARAMETERS_DIRTY) && bank_changed)
                snapshot_dirty_r <= 1'b1;
        end
    end
    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            for (capture_index=0;capture_index<8;capture_index=capture_index+1) knob_delta_captured[capture_index] <= 2'sd0;
            knob_pressed_event_captured <= '0;
            mode_captured <= '0;
            fine_adjust_captured <= '0;
            edit_enable_captured <= '0;
            edit_target_captured <= '0;
            clear_wave_progress_captured <= '0;
            wavetable_0_previous <= 4'd0;
            wavetable_1_previous <= 4'd1;
            interp_percent_previous <= 7'd0;
            detune_percent_previous <= 7'd0;
            attack_ms_previous <= 11'd5;
            decay_ms_previous <= 11'd150;
            sustain_percent_previous <= 7'd70;
            release_ms_previous <= 13'd200;
            master_gain_previous <= 16'h8000;
            balance_gain_previous <= 16'h8000;
            advanced_previous <= {CHORUS_DEPTH_DEFAULT, CHORUS_RATE_DEFAULT, DISTORTION_TONE_DEFAULT, DISTORTION_GAIN_DEFAULT, DELAY_FEEDBACK_DEFAULT, DELAY_TIME_DEFAULT, REVERB_DAMPING_DEFAULT, REVERB_FEEDBACK_DEFAULT};
            make_up_previous <= {4{16'h8000}};
            effect_select_captured <= 2'd0;
            effect_reset_captured <= 1'b0;
            reverb_mix_percent_previous <= 7'd0;
            delay_mix_percent_previous <= 7'd0;
            distortion_mix_percent_previous <= 7'd0;
            chorus_mix_percent_previous <= 7'd0;
        end
        else if (in_valid && event_accept_enable)
        begin
            for (capture_index=0;capture_index<8;capture_index=capture_index+1) knob_delta_captured[capture_index] <= knob_delta[capture_index];
            knob_pressed_event_captured <= knob_pressed_event;
            mode_captured <= mode;
            fine_adjust_captured <= fine_adjust;
            edit_enable_captured <= edit_enable;
            edit_target_captured <= edit_target;
            clear_wave_progress_captured <= clear_wave_progress;
            wavetable_0_previous <= wavetable_0_r;
            wavetable_1_previous <= wavetable_1_r;
            interp_percent_previous <= interp_percent_r;
            detune_percent_previous <= detune_percent_r;
            attack_ms_previous <= attack_ms_r;
            decay_ms_previous <= decay_ms_r;
            sustain_percent_previous <= sustain_percent_r;
            release_ms_previous <= release_ms_r;
            master_gain_previous <= master_gain_r;
            balance_gain_previous <= balance_gain_r;
            advanced_previous <= advanced_r;
            make_up_previous <= make_up_r;
            effect_select_captured <= effect_select;
            effect_reset_captured <= effect_reset;
            reverb_mix_percent_previous <= reverb_mix_percent_r;
            delay_mix_percent_previous <= delay_mix_percent_r;
            distortion_mix_percent_previous <= distortion_mix_percent_r;
            chorus_mix_percent_previous <= chorus_mix_percent_r;
        end
    end

    reg display_update_r;
    reg [21:0] display_activity_r, display_reset_r;
    reg [21:0] action_activity, action_reset;
    integer display_knob;
    integer parameter_id;
    assign display_master_gain = master_gain_r;
    assign display_update = display_update_r;
    assign display_activity_mask = display_activity_r;
    assign display_reset_mask = display_reset_r;

    // Decode accepted/captured actions, not value differences. Thus a turn at
    // MIN/MAX and pressing an already-default knob remain visible to the UI.
    always @(*)
    begin
        action_activity = 22'd0;
        action_reset = 22'd0;
        parameter_id = 0;
        if (edit_enable_captured && !edit_target_captured && mode_captured < 2'd2)
        begin
            for (display_knob = 0; display_knob < 8; display_knob = display_knob + 1)
            begin
                case (display_knob)
                    0: parameter_id = (mode_captured == 2'd0) ? 0 : 1;
                    1: parameter_id = (mode_captured == 2'd0) ? 2 : 3;
                    2: parameter_id = 4;
                    3: parameter_id = 5;
                    default: parameter_id = ((mode_captured == 2'd0) ? 6 : 10) + display_knob - 4;
                endcase
                if (knob_delta_captured[display_knob] != 2'sd0 || knob_pressed_event_captured[display_knob])
                    action_activity[parameter_id] = 1'b1;
                if (knob_pressed_event_captured[display_knob]) action_reset[parameter_id] = 1'b1;
            end
        end
        if (mode_captured == 2'd2)
        begin
            for (display_knob = 0; display_knob < 2; display_knob = display_knob + 1)
            begin
                parameter_id = 14 + 2 * effect_select_captured + display_knob;
                if (effect_reset_captured || (edit_enable_captured &&
                    (knob_delta_captured[display_knob] != 2'sd0 || knob_pressed_event_captured[display_knob])))
                    action_activity[parameter_id] = 1'b1;
                if (effect_reset_captured || (edit_enable_captured && knob_pressed_event_captured[display_knob]))
                    action_reset[parameter_id] = 1'b1;
            end
            if (effect_reset_captured)
            begin
                action_activity[10 + effect_select_captured] = 1'b1;
                action_reset[10 + effect_select_captured] = 1'b1;
            end
            if (edit_enable_captured &&
                (knob_delta_captured[2] != 2'sd0 || knob_pressed_event_captured[2]))
                action_activity[10 + effect_select_captured] = 1'b1;
            if (edit_enable_captured && knob_pressed_event_captured[2])
                action_reset[10 + effect_select_captured] = 1'b1;
        end
    end
    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            display_update_r <= 1'b0;
            display_activity_r <= 22'd0;
            display_reset_r <= 22'd0;
        end
        else
        begin
            display_update_r <= 1'b0;
            display_activity_r <= 22'd0;
            display_reset_r <= 22'd0;
            if (current_state == STATE_CALCULATE_FRAME)
            begin
                display_update_r <= 1'b1;
                display_activity_r <= action_activity;
                display_reset_r <= action_reset;
            end
            if (preset_wave_load_pending_r)
            begin
                display_update_r <= 1'b1;
                display_activity_r <= 22'h3fffef; // Every loaded field except master bit4.
                display_reset_r <= 22'd0;        // Loading a preset is not DEFAULT.
            end
        end
    end
endmodule
