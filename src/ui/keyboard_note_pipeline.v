/**
 * 键盘与弯音处理顶层 v4
 * v4 版本修改：寄存基频与倍率的共同有效标志，隔开握手判断与整组装载。
 * 连接按键事件、声部分配、基频换算、弯音和压力平滑。
 * 弯音频率 = 基频 * 2^(音分/1200)；子模块采用 LUT 查表／乘法，不使用 DSP。
 * 琴键与轮子位置同帧保存；频率和力度均完成后，连同起音／松开通知整组交付。
 */

/**
 * bend_value: 与琴键同帧的 16 位位置，0000/8000/ffff 对应下端／中心／上端。
 * smp_tick_up: 启动采样计算；最早在其后 3*MAX_POLYPHONY+10 沿交付，32 声部为 106 沿。
 * sample_ready: 可启动下一采样；sample_overrun: 尚未完成又来了采样脉冲。
 * VELOCITY_SLEW_STEP: 每次采样的最大力度变化，UQ0.16 编码；无新输入也继续平滑。
 * clk_sys 上升沿 valid && ready 接收或交付；背压时保持整组结果与 valid。
 * NOTE: note_on/off 只交付一次；同拍新完成的键盘结果留到后续采样，不按固定拍数接收。
 */
module keyboard_note_pipeline
#(
    parameter KEY_NUM = 24,  // 琴键数量，1～24，按 C4 起连续编号
    parameter MAX_POLYPHONY = 32,  // 声部数量，默认 32
    parameter KEY_ID_WIDTH = (KEY_NUM > 1) ? $clog2(KEY_NUM) : 1,  // 琴键编号位宽，至少为 1
    parameter [15:0] VELOCITY_SLEW_STEP = 16'd274  // 每次采样最大力度变化，UQ0.16 编码；274 对应满程约 5 ms（48 kHz）
)(
    input clk_sys,
    input rst_n,
    input scan_tick_up,
    input smp_tick_up,
    input [KEY_NUM-1:0] key_states,
    input [15:0] key_velocity [KEY_NUM-1:0],
    input [15:0] bend_value,
    input [MAX_POLYPHONY-1:0] note_busy,
    input in_valid,
    output in_ready,
    output [MAX_POLYPHONY-1:0] note_on,
    output [MAX_POLYPHONY-1:0] note_off,
    output [31:0] note_freq [MAX_POLYPHONY-1:0],
    output [15:0] note_velocity [MAX_POLYPHONY-1:0],
    output out_valid,
    input out_ready,
    output sample_ready,
    output sample_overrun
);
    localparam STATE_WAIT_SAMPLE_TICK = 3'd0;
    localparam STATE_CAPTURE_SAMPLE_INPUT = 3'd1;
    localparam STATE_START_CONVERSION = 3'd2;
    localparam STATE_WAIT_CONVERSION_RESULTS = 3'd3;
    localparam STATE_WAIT_AUDIO_ACCEPT = 3'd4;
    wire [2:0] current_state;
    reg [2:0] next_state;
    wire event_valid;
    wire event_ready;
    wire [MAX_POLYPHONY-1:0] event_on;
    wire [MAX_POLYPHONY-1:0] event_off;
    wire [MAX_POLYPHONY-1:0] event_occupied;
    wire [MAX_POLYPHONY-1:0] event_held;
    wire [KEY_ID_WIDTH-1:0] event_key_id [MAX_POLYPHONY-1:0];
    wire [15:0] event_pressure [KEY_NUM-1:0];
    reg [KEY_ID_WIDTH-1:0] latest_key_id_r [MAX_POLYPHONY-1:0];
    reg [15:0] latest_pressure_r [KEY_NUM-1:0];
    reg [MAX_POLYPHONY-1:0] latest_occupied_r;
    reg [MAX_POLYPHONY-1:0] latest_held_r;
    reg [MAX_POLYPHONY-1:0] sample_on_r;
    reg [MAX_POLYPHONY-1:0] sample_off_r;
    reg sample_has_frame_r;
    reg sample_overrun_r;
    reg [15:0] event_bend_r;
    reg [15:0] latest_bend_r;
    wire [31:0] base_frequency [MAX_POLYPHONY-1:0];
    wire [17:0] bend_ratio;
    wire ratio_valid;
    wire pitch_input_ready;
    wire pitch_valid;
    wire pitch_input_valid;
    wire pitch_input_accept;
    reg pitch_inputs_valid_r;
    wire frequency_ready;
    wire velocity_ready;
    wire frequency_valid;
    wire velocity_valid;
    wire conversion_valid;
    wire result_accept;
    integer voice;
    integer key_index;
    // 两路结果已经确认并保持，公开 valid 不再组合穿过子模块计算完成信号。
    assign out_valid = (current_state == STATE_WAIT_AUDIO_ACCEPT);
    assign result_accept = out_valid && out_ready;
    assign event_ready = result_accept && sample_has_frame_r;
    wire sample_available;
    assign sample_available = (current_state == STATE_WAIT_SAMPLE_TICK) || result_accept;
    assign sample_ready = rst_n && sample_available;
    assign sample_overrun = sample_overrun_r;
    assign note_on = sample_on_r;
    assign note_off = sample_off_r;
    // 上一整组结果已共同接收才进入本状态，两子模块均空闲；发送 valid 不等待 ready。
    assign conversion_valid = (current_state == STATE_START_CONVERSION);
    assign pitch_input_valid = pitch_inputs_valid_r;
    assign pitch_input_accept = pitch_input_valid && pitch_input_ready;

    // 只寄存共同就绪的决定，不提前确认上游；两路数据保持到真正交付。
    // valid 的产生不依赖 ready；背压时保持，交付同沿清除，避免重复送入。
    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
            pitch_inputs_valid_r <= 1'b0;
        else if (pitch_input_accept)
            pitch_inputs_valid_r <= 1'b0;
        else if (frequency_valid && ratio_valid)
            pitch_inputs_valid_r <= 1'b1;
    end

    keyboard_event_handler #(
        .KEY_NUM(KEY_NUM), .MAX_POLYPHONY(MAX_POLYPHONY), .KEY_ID_WIDTH(KEY_ID_WIDTH)
    ) keyboard_event_handler_u (
        .clk_sys(clk_sys), .rst_n(rst_n), .scan_tick_up(scan_tick_up),
        .key_states(key_states), .key_velocity(key_velocity), .note_busy(note_busy),
        .note_on(event_on), .note_off(event_off), .key_id(event_key_id),
        .occupied(event_occupied), .held(event_held), .frame_velocity(event_pressure),
        .in_valid(in_valid), .in_ready(in_ready), .out_valid(event_valid), .out_ready(event_ready)
    );
    note_frequency_mapper #(
        .KEY_NUM(KEY_NUM), .MAX_POLYPHONY(MAX_POLYPHONY), .KEY_ID_WIDTH(KEY_ID_WIDTH)
    ) note_frequency_mapper_u (
        .clk_sys(clk_sys), .rst_n(rst_n), .key_id(latest_key_id_r), .occupied(latest_occupied_r),
        .in_valid(conversion_valid), .in_ready(frequency_ready), .note_freq(base_frequency),
        .out_valid(frequency_valid), .out_ready(pitch_input_accept)
    );
    pitch_bend_controller pitch_bend_controller_u (
        .clk_sys(clk_sys), .rst_n(rst_n), .bend_value(latest_bend_r),
        .in_valid(conversion_valid), .in_ready(), .bend_ratio(bend_ratio),
        .out_valid(ratio_valid), .out_ready(pitch_input_accept)
    );
    note_pitch_bend #(.MAX_POLYPHONY(MAX_POLYPHONY)) note_pitch_bend_u (
        .clk_sys(clk_sys), .rst_n(rst_n), .base_freq(base_frequency), .bend_ratio(bend_ratio),
        .in_valid(pitch_input_valid), .in_ready(pitch_input_ready), .note_freq(note_freq),
        .out_valid(pitch_valid), .out_ready(result_accept)
    );
    note_velocity_controller #(
        .KEY_NUM(KEY_NUM), .MAX_POLYPHONY(MAX_POLYPHONY), .KEY_ID_WIDTH(KEY_ID_WIDTH),
        .SLEW_STEP(VELOCITY_SLEW_STEP)
    ) note_velocity_controller_u (
        .clk_sys(clk_sys), .rst_n(rst_n), .key_id(latest_key_id_r), .key_velocity(latest_pressure_r),
        .occupied(latest_occupied_r), .held(latest_held_r), .note_on(sample_on_r),
        .in_valid(conversion_valid), .in_ready(velocity_ready), .note_velocity(note_velocity),
        .out_valid(velocity_valid), .out_ready(result_accept)
    );
    fsm #(.W(3), .INITIAL_STATE(STATE_WAIT_SAMPLE_TICK)) fsm_u (
        .clk(clk_sys), .rst_n(rst_n), .stn(next_state), .stc(current_state)
    );
    always @(*)
    begin
        next_state = current_state;
        case (current_state)
            STATE_WAIT_SAMPLE_TICK:
                if (smp_tick_up) next_state = STATE_CAPTURE_SAMPLE_INPUT;
            STATE_CAPTURE_SAMPLE_INPUT:
                next_state = STATE_START_CONVERSION;
            STATE_START_CONVERSION:
                next_state = STATE_WAIT_CONVERSION_RESULTS;
            STATE_WAIT_CONVERSION_RESULTS:
                if (pitch_valid && velocity_valid) next_state = STATE_WAIT_AUDIO_ACCEPT;
            STATE_WAIT_AUDIO_ACCEPT:
                if (result_accept) next_state = smp_tick_up ? STATE_CAPTURE_SAMPLE_INPUT : STATE_WAIT_SAMPLE_TICK;
            default: next_state = STATE_WAIT_SAMPLE_TICK;
        endcase
    end
    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            latest_occupied_r <= '0;
            latest_held_r <= '0;
            sample_on_r <= '0;
            sample_off_r <= '0;
            sample_has_frame_r <= 1'b0;
            sample_overrun_r <= 1'b0;
            event_bend_r <= 16'h8000;
            latest_bend_r <= 16'h8000;
            for (voice = 0; voice < MAX_POLYPHONY; voice = voice + 1)
                latest_key_id_r[voice] <= '0;
            for (key_index = 0; key_index < KEY_NUM; key_index = key_index + 1)
                latest_pressure_r[key_index] <= 16'd0;
        end
        else
        begin
            // 事件模块一次只允许一个未交付事务，此寄存器随同一次键盘握手保存。
            if (in_valid && in_ready) event_bend_r <= bend_value;
            if (smp_tick_up && !sample_ready) sample_overrun_r <= 1'b1;
            // 外层异步复位优先；内部判定不绕行公共 ready 的复位门控。
            if (smp_tick_up && sample_available)
            begin
                // 同沿交付旧帧时 event_valid 仍为高，必须排除已接收的旧结果。
                sample_has_frame_r <= event_valid && !event_ready;
                sample_on_r <= (event_valid && !event_ready) ? event_on : {MAX_POLYPHONY{1'b0}};
                sample_off_r <= (event_valid && !event_ready) ? event_off : {MAX_POLYPHONY{1'b0}};
            end
            // 使用上一拍锁存的决定驱动大组寄存器，切断 ready 到数据使能的组合长路径。
            // 此时 event_ready 必为零；没有在 tick 选中的新帧不能提前进入本次采样。
            if ((current_state == STATE_CAPTURE_SAMPLE_INPUT) && sample_has_frame_r)
            begin
                latest_bend_r <= event_bend_r;
                latest_occupied_r <= event_occupied;
                latest_held_r <= event_held;
                for (voice = 0; voice < MAX_POLYPHONY; voice = voice + 1)
                    latest_key_id_r[voice] <= event_key_id[voice];
                for (key_index = 0; key_index < KEY_NUM; key_index = key_index + 1)
                    latest_pressure_r[key_index] <= event_pressure[key_index];
            end
        end
    end
endmodule
