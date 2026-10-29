/**
 * 旋钮参数模块 v5：修改音色参数，处理粗细调、限幅和恢复默认值。
 * v5 版本修改：音色先暂存并准备分组装载标记，下一拍握手时整组生效。
 * knob_delta: 每路 -1/0/+1 步；mode/fine_adjust: 本次使用的模式及微调开关。
 * 参数按百分比、角度、毫秒保存；按下旋钮恢复默认，优先于同次转动。
 * frame_done_valid: 本次旋钮已处理完成，即使没有修改参数也返回确认。
 * parameter_valid: 有一整组参数可读取；等待时保持，后续修改留到下一组输出。
 * WAVE_SELECT_STEPS: 换一张波形需累计的步数，合法范围 1～32767。
 * TODO: 默认值 0 表示未配置，会阻止正常工作；产品取值待定。
 */
module knob_parameter_controller
#(
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
    input in_valid,
    output in_ready,
    output frame_done_valid,
    input frame_done_ready,
    output configuration_error,
    output signed [15:0] wave_progress,
    output [3:0] wavetable_0 [0:0],
    output [3:0] wavetable_1 [0:0],
    output [6:0] interp_percent [0:0],
    output [8:0] phase_degrees [0:0],
    output [10:0] attack_ms [0:0],
    output [10:0] decay_ms [0:0],
    output [6:0] sustain_percent [0:0],
    output [12:0] release_ms [0:0],
    output [6:0] master_percent,
    output [6:0] balance_percent,  // 音色增益快照，0..100；本轮只由音色加载修改，K4留待后续
    output [6:0] reverb_mix_percent,
    output [6:0] delay_mix_percent,
    output [6:0] distortion_mix_percent,
    output [6:0] chorus_mix_percent,
    output parameter_valid,
    input parameter_ready,
    // 已校验的整组音色；优先于下一次旋钮事件，总音量保持不变。
    // NOTE: 空闲时先准备一拍再给 ready；valid 和参数须保持到握手，握手沿整组生效。
    input preset_load_valid,
    output preset_load_ready,
    input [191:0] preset_load_parameters,
    input [6:0] preset_load_balance_percent,
    output [6:0] preset_current_balance_percent,
    output [191:0] preset_current_parameters
);
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
    reg [8:0] phase_degrees_previous;
    reg [10:0] attack_ms_previous;
    reg [10:0] decay_ms_previous;
    reg [6:0] sustain_percent_previous;
    reg [12:0] release_ms_previous;
    reg [6:0] master_percent_previous;
    reg [6:0] reverb_mix_percent_previous;
    reg [6:0] delay_mix_percent_previous;
    reg [6:0] distortion_mix_percent_previous;
    reg [6:0] chorus_mix_percent_previous;
    // 依次等待输入、计算修改、标记更新、等待本次处理完成被接收。
    localparam STATE_WAIT_EVENT_FRAME = 2'd0;
    localparam STATE_CALCULATE_FRAME = 2'd1;
    localparam STATE_MARK_PARAMETERS_DIRTY = 2'd2;
    localparam STATE_WAIT_COMPLETION_ACCEPT = 2'd3;
    // 余量范围为 -(steps-1)～+(steps-1)，包含符号位；
    // 候选结果再扩一位，保证达到阈值时的加法不溢出。
    localparam WAVE_PROGRESS_WIDTH = (WAVE_SELECT_STEPS > 1) ? $clog2(WAVE_SELECT_STEPS) + 1 : 2;
    wire [1:0] current_state;
    reg [1:0] next_state;
    reg signed [WAVE_PROGRESS_WIDTH-1:0] wave_progress_r;
    reg signed [WAVE_PROGRESS_WIDTH-1:0] wave_progress_next;
    reg signed [WAVE_PROGRESS_WIDTH:0] wave_sum;
    reg snapshot_valid_r;
    reg snapshot_dirty_r;
    // 仅本地装载标记驱动整组快照；不能用上一拍 ready 代替当前握手。
    reg snapshot_load_pending_r /* synthesis syn_preserve = 1 */;
    // 数据逐拍暂存；只有准备完成后的握手沿才更新可见参数。
    reg [191:0] preset_parameters_sampled_r;
    reg [6:0] preset_balance_sampled_r;
    reg [6:0] balance_percent_r;
    reg [6:0] balance_percent_snapshot_r;
    assign balance_percent = balance_percent_snapshot_r;
    assign preset_current_balance_percent = balance_percent_r;
    // 三组同拍准备、同拍装载，分别驱动波形／相位、ADSR、效果比例。
    reg preset_wave_load_pending_r /* synthesis syn_preserve = 1 */;
    reg preset_envelope_load_pending_r /* synthesis syn_preserve = 1 */;
    reg preset_effect_load_pending_r /* synthesis syn_preserve = 1 */;
    wire bank_changed;
    // 先限幅到字段合法范围，再明确截取结果位宽。
    wire [31:0] master_percent_adjusted;
    assign master_percent_adjusted = adjust_value(master_percent_r, knob_delta_captured[2],
        fine_adjust_captured ? 32'd1 : 32'd5, 32'd0, 32'd100);
    wire [31:0] interp_percent_adjusted;
    assign interp_percent_adjusted = adjust_value(interp_percent_r, knob_delta_captured[1],
        fine_adjust_captured ? 32'd1 : 32'd5, 32'd0, 32'd100);
    wire [31:0] phase_degrees_adjusted;
    assign phase_degrees_adjusted = adjust_value(phase_degrees_r, knob_delta_captured[1],
        fine_adjust_captured ? 32'd1 : 32'd5, 32'd0, 32'd359);
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
    reg [8:0] phase_degrees_r;
    reg [8:0] phase_degrees_next;
    reg [8:0] phase_degrees_snapshot_r;
    assign phase_degrees[0] = phase_degrees_snapshot_r;
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
    reg [6:0] master_percent_r;
    reg [6:0] master_percent_next;
    reg [6:0] master_percent_snapshot_r;
    assign master_percent = master_percent_snapshot_r;
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
        {7'd0, phase_degrees_r},
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
    assign bank_changed = (wavetable_0_previous != wavetable_0_r) ||
        (wavetable_1_previous != wavetable_1_r) ||
        (interp_percent_previous != interp_percent_r) ||
        (phase_degrees_previous != phase_degrees_r) ||
        (attack_ms_previous != attack_ms_r) ||
        (decay_ms_previous != decay_ms_r) ||
        (sustain_percent_previous != sustain_percent_r) ||
        (release_ms_previous != release_ms_r) ||
        (master_percent_previous != master_percent_r) ||
        (reverb_mix_percent_previous != reverb_mix_percent_r) ||
        (delay_mix_percent_previous != delay_mix_percent_r) ||
        (distortion_mix_percent_previous != distortion_mix_percent_r) ||
        (chorus_mix_percent_previous != chorus_mix_percent_r);

    fsm #(
        .W(2), .INITIAL_STATE(STATE_WAIT_EVENT_FRAME)
    ) fsm_u (
        .clk(clk_sys), .rst_n(rst_n), .stn(next_state), .stc(current_state)
    );
    always @(*)
    begin
        next_state = current_state;
        case (current_state)
            STATE_WAIT_EVENT_FRAME:
                if (in_valid && event_accept_enable) next_state = STATE_CALCULATE_FRAME;
            STATE_CALCULATE_FRAME: next_state = STATE_MARK_PARAMETERS_DIRTY;
            STATE_MARK_PARAMETERS_DIRTY: next_state = STATE_WAIT_COMPLETION_ACCEPT;
            STATE_WAIT_COMPLETION_ACCEPT:
                if (frame_done_ready) next_state = STATE_WAIT_EVENT_FRAME;
            default: next_state = STATE_WAIT_EVENT_FRAME;
        endcase
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
        wavetable_0_next = wavetable_0_r;
        wavetable_1_next = wavetable_1_r;
        interp_percent_next = interp_percent_r;
        phase_degrees_next = phase_degrees_r;
        attack_ms_next = attack_ms_r;
        decay_ms_next = decay_ms_r;
        sustain_percent_next = sustain_percent_r;
        release_ms_next = release_ms_r;
        master_percent_next = master_percent_r;
        reverb_mix_percent_next = reverb_mix_percent_r;
        delay_mix_percent_next = delay_mix_percent_r;
        distortion_mix_percent_next = distortion_mix_percent_r;
        chorus_mix_percent_next = chorus_mix_percent_r;
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
            if (knob_pressed_event_captured[2]) master_percent_next = 7'd30;
            else master_percent_next = master_percent_adjusted[6:0];
            if (mode_captured == 2'd0)
            begin
                if (knob_pressed_event_captured[1]) interp_percent_next = 7'd0;
                else interp_percent_next = interp_percent_adjusted[6:0];
            end
            if (mode_captured == 2'd1)
            begin
                if (knob_pressed_event_captured[1]) phase_degrees_next = 9'd0;
                else phase_degrees_next = phase_degrees_adjusted[8:0];
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
            preset_balance_sampled_r <= 7'd100;
            preset_wave_load_pending_r <= 1'b0;
            preset_envelope_load_pending_r <= 1'b0;
            preset_effect_load_pending_r <= 1'b0;
        end
        else
        begin
            // 这里不使用握手作为宽总线使能，避免把原长路径搬到暂存寄存器。
            preset_parameters_sampled_r <= preset_load_parameters;
            preset_balance_sampled_r <= preset_load_balance_percent;
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
            phase_degrees_snapshot_r <= 9'd0;
            attack_ms_snapshot_r <= 11'd5;
            decay_ms_snapshot_r <= 11'd150;
            sustain_percent_snapshot_r <= 7'd70;
            release_ms_snapshot_r <= 13'd200;
            master_percent_snapshot_r <= 7'd30;
            balance_percent_snapshot_r <= 7'd100;
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
            phase_degrees_snapshot_r <= phase_degrees_r;
            attack_ms_snapshot_r <= attack_ms_r;
            decay_ms_snapshot_r <= decay_ms_r;
            sustain_percent_snapshot_r <= sustain_percent_r;
            release_ms_snapshot_r <= release_ms_r;
            master_percent_snapshot_r <= master_percent_r;
            balance_percent_snapshot_r <= balance_percent_r;
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
            phase_degrees_r <= 9'd0;
            attack_ms_r <= 11'd5;
            decay_ms_r <= 11'd150;
            sustain_percent_r <= 7'd70;
            release_ms_r <= 13'd200;
            master_percent_r <= 7'd30;
            balance_percent_r <= 7'd100;
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
                phase_degrees_r <= phase_degrees_next;
                attack_ms_r <= attack_ms_next;
                decay_ms_r <= decay_ms_next;
                sustain_percent_r <= sustain_percent_next;
                release_ms_r <= release_ms_next;
                master_percent_r <= master_percent_next;
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
                phase_degrees_r <= preset_parameters_sampled_r[56:48];
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
                // 同组装载音色增益；master_percent_r 不在加载分支更新。
                balance_percent_r <= preset_balance_sampled_r;
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
            phase_degrees_previous <= 9'd0;
            attack_ms_previous <= 11'd5;
            decay_ms_previous <= 11'd150;
            sustain_percent_previous <= 7'd70;
            release_ms_previous <= 13'd200;
            master_percent_previous <= 7'd30;
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
            phase_degrees_previous <= phase_degrees_r;
            attack_ms_previous <= attack_ms_r;
            decay_ms_previous <= decay_ms_r;
            sustain_percent_previous <= sustain_percent_r;
            release_ms_previous <= release_ms_r;
            master_percent_previous <= master_percent_r;
            reverb_mix_percent_previous <= reverb_mix_percent_r;
            delay_mix_percent_previous <= delay_mix_percent_r;
            distortion_mix_percent_previous <= distortion_mix_percent_r;
            chorus_mix_percent_previous <= chorus_mix_percent_r;
        end
    end
endmodule
