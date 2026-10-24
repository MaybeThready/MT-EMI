/**
 * note_velocity_controller 模块 v2
 * v2版本修改：压力选取与最低值判断分拍，缩短计算路径。
 * 将琴键压力换算成声部力度，按住时平滑变化，松开后保持最后力度。
 * key_id/key_velocity: 对应键号与压力；须和 occupied、held、note_on 属于同次输入。
 * note_velocity: 16 位 UQ0.16 压力音量，不包含总音量和 ADSR。
 * MIN_VELOCITY: 最小力度，3277 约为 5%；SLEW_STEP: 每次采样最大变化量。
 * 新音直接采用不低于最小值的压力；默认步长 274 在 48 kHz 下满程约 5 ms。
 * IF-KEYBOARD-07：输入接收、下限处理、候选计算、更新分四拍；
 * 最早在接收后的第四个上升沿交付，数值与背压规则不变。
 * NOTE: 只使用加减比较；等待接收时保持结果，不重复推进平滑。
 */
module note_velocity_controller
#(
    parameter KEY_NUM = 24,  // 琴键数量，至少为 1
    parameter MAX_POLYPHONY = 32,  // 声部数量，默认 32
    parameter KEY_ID_WIDTH = (KEY_NUM > 1) ? $clog2(KEY_NUM) : 1,  // 琴键编号位宽，至少为 1
    parameter [15:0] MIN_VELOCITY = 16'd3277,  // 最小压力音量，UQ0.16；3277 约为 5%
    parameter [15:0] SLEW_STEP = 16'd274  // 每次采样最大力度变化，UQ0.16 编码
)(
    input clk_sys,
    input rst_n,
    input [KEY_ID_WIDTH-1:0] key_id [MAX_POLYPHONY-1:0],
    input [15:0] key_velocity [KEY_NUM-1:0],
    input [MAX_POLYPHONY-1:0] occupied,
    input [MAX_POLYPHONY-1:0] held,
    input [MAX_POLYPHONY-1:0] note_on,
    input in_valid,
    output in_ready,
    output [15:0] note_velocity [MAX_POLYPHONY-1:0],
    output out_valid,
    input out_ready
);
    localparam STATE_WAIT_SAMPLE = 3'd0;
    localparam STATE_CLAMP_TARGET_PRESSURE = 3'd1;
    localparam STATE_CALCULATE_STEP_CANDIDATES = 3'd2;
    localparam STATE_APPLY_SMOOTHING = 3'd3;
    localparam STATE_WAIT_RESULT_ACCEPT = 3'd4;
    localparam signed [16:0] POSITIVE_SLEW_STEP = $signed({1'b0, SLEW_STEP});
    localparam signed [16:0] NEGATIVE_SLEW_STEP = -POSITIVE_SLEW_STEP;
    wire [2:0] current_state;
    reg [2:0] next_state;
    reg [15:0] velocity_r [MAX_POLYPHONY-1:0];
    wire [15:0] selected_pressure [MAX_POLYPHONY-1:0];
    reg [15:0] pressure_r [MAX_POLYPHONY-1:0];
    reg [15:0] target_r [MAX_POLYPHONY-1:0];
    reg signed [16:0] difference_r [MAX_POLYPHONY-1:0];
    reg [15:0] increased_velocity_r [MAX_POLYPHONY-1:0];
    reg [15:0] decreased_velocity_r [MAX_POLYPHONY-1:0];
    reg [MAX_POLYPHONY-1:0] occupied_r;
    reg [MAX_POLYPHONY-1:0] held_r;
    reg [MAX_POLYPHONY-1:0] note_on_r;
    integer voice;
    integer candidate_voice;
    genvar voice_index;

    generate
        for (voice_index = 0; voice_index < MAX_POLYPHONY; voice_index = voice_index + 1)
        begin : velocity_outputs
            assign selected_pressure[voice_index] = (key_id[voice_index] < KEY_NUM) ?
                key_velocity[key_id[voice_index]] : 16'd0;
            assign note_velocity[voice_index] = velocity_r[voice_index];
        end
    endgenerate
    assign in_ready = rst_n && (current_state == STATE_WAIT_SAMPLE);
    // 复位状态本身无有效结果；异步复位仍保留在状态与数据寄存器。
    assign out_valid = (current_state == STATE_WAIT_RESULT_ACCEPT);
    fsm #(.W(3), .INITIAL_STATE(STATE_WAIT_SAMPLE)) fsm_u (
        .clk(clk_sys), .rst_n(rst_n), .stn(next_state), .stc(current_state)
    );
    always @(*)
    begin
        case (current_state)
            STATE_WAIT_SAMPLE: next_state = in_valid ? STATE_CLAMP_TARGET_PRESSURE : STATE_WAIT_SAMPLE;
            STATE_CLAMP_TARGET_PRESSURE: next_state = STATE_CALCULATE_STEP_CANDIDATES;
            STATE_CALCULATE_STEP_CANDIDATES: next_state = STATE_APPLY_SMOOTHING;
            STATE_APPLY_SMOOTHING: next_state = STATE_WAIT_RESULT_ACCEPT;
            STATE_WAIT_RESULT_ACCEPT: next_state = out_ready ? STATE_WAIT_SAMPLE : STATE_WAIT_RESULT_ACCEPT;
            default: next_state = STATE_WAIT_SAMPLE;
        endcase
    end
    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            occupied_r <= '0;
            held_r <= '0;
            note_on_r <= '0;
            for (voice = 0; voice < MAX_POLYPHONY; voice = voice + 1)
            begin
                velocity_r[voice] <= 16'd0;
                pressure_r[voice] <= 16'd0;
                target_r[voice] <= 16'd0;
            end
        end
        else if (in_valid && (current_state == STATE_WAIT_SAMPLE))
        begin
            held_r <= held;
            note_on_r <= note_on;
            for (voice = 0; voice < MAX_POLYPHONY; voice = voice + 1)
            begin
                occupied_r[voice] <= occupied[voice] && (key_id[voice] < KEY_NUM);
                pressure_r[voice] <= selected_pressure[voice];
            end
        end
        else if (current_state == STATE_CLAMP_TARGET_PRESSURE)
        begin
            // 压力多路选择和最低 5% 比较分拍；使用已接收的压力，不读取变化中的输入。
            for (voice = 0; voice < MAX_POLYPHONY; voice = voice + 1)
                target_r[voice] <= (pressure_r[voice] < MIN_VELOCITY) ?
                    MIN_VELOCITY : pressure_r[voice];
        end
        else if (current_state == STATE_APPLY_SMOOTHING)
        begin
            for (voice = 0; voice < MAX_POLYPHONY; voice = voice + 1)
            begin
                if (!occupied_r[voice])
                    velocity_r[voice] <= 16'd0;
                else if (note_on_r[voice])
                    velocity_r[voice] <= target_r[voice];
                else if (held_r[voice])
                begin
                    if (difference_r[voice] > POSITIVE_SLEW_STEP)
                        velocity_r[voice] <= increased_velocity_r[voice];
                    else if (difference_r[voice] < NEGATIVE_SLEW_STEP)
                        velocity_r[voice] <= decreased_velocity_r[voice];
                    else
                        velocity_r[voice] <= target_r[voice];
                end
            end
        end
    end
    // 中间候选连续计算，不需要一个状态信号驱动 32 路的 1568 个 CE。
    // E0 原始压力捕获，E1 下限处理，E2 候选稳定；只有 E3 提交状态改变公开力度。
    // 背压期间中间量可变化，公开结果仍保持；异步复位行为保持原约定。
    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            for (candidate_voice = 0; candidate_voice < MAX_POLYPHONY; candidate_voice = candidate_voice + 1)
            begin
                difference_r[candidate_voice] <= 17'sd0;
                increased_velocity_r[candidate_voice] <= 16'd0;
                decreased_velocity_r[candidate_voice] <= 16'd0;
            end
        end
        else
        begin
            for (candidate_voice = 0; candidate_voice < MAX_POLYPHONY; candidate_voice = candidate_voice + 1)
            begin
                difference_r[candidate_voice] <= $signed({1'b0, target_r[candidate_voice]}) - $signed({1'b0, velocity_r[candidate_voice]});
                // 候选允许模 65536 运算；仅在差值超过步长时选用对应方向。
                // 此时 current+step<target<=65535 或 current-step>target>=0，
                // 因此被选中的候选必不溢出；步长以内直接选目标值。
                increased_velocity_r[candidate_voice] <= velocity_r[candidate_voice] + SLEW_STEP;
                decreased_velocity_r[candidate_voice] <= velocity_r[candidate_voice] - SLEW_STEP;
            end
        end
    end
    // synthesis translate_off
    initial
    begin
        if ((KEY_NUM < 1) || (MAX_POLYPHONY < 1) || (SLEW_STEP == 16'd0))
            $fatal(1, "非法力度配置");
    end
    // synthesis translate_on
endmodule
