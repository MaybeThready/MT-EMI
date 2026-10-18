/**
 * 键盘处理顶层：连接按键检测、声部分配、音高换算和压力平滑。
 * smp_tick_up: 启动一次音符输出；没有新输入时仍更新压力平滑。
 * sample_ready: 可以开始下一次计算；sample_overrun: 尚未完成又来了采样脉冲。
 * note_on/note_off: 每次输入产生的通知只交付一次，不随后续采样重复发送。
 * 等待音频接收时保持结果；同拍新算出的按键结果留到下次采样使用。
 * VELOCITY_SLEW_STEP: 每次采样的最大力度变化，UQ0.16 编码。
 * TODO: 当前只输出基准音高，未加入弯音。
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
    localparam STATE_WAIT_SAMPLE_TICK = 2'd0;
    localparam STATE_START_CONVERSION = 2'd1;
    localparam STATE_WAIT_AUDIO_ACCEPT = 2'd2;
    wire [1:0] current_state;
    reg [1:0] next_state;
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
    wire frequency_ready;
    wire velocity_ready;
    wire frequency_valid;
    wire velocity_valid;
    wire conversion_valid;
    wire result_accept;
    integer voice;
    integer key_index;
    // 状态及子模块 valid 均异步清零，不再串接高扇出复位网。
    assign out_valid = (current_state == STATE_WAIT_AUDIO_ACCEPT) && frequency_valid && velocity_valid;
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
        .in_valid(conversion_valid), .in_ready(frequency_ready), .note_freq(note_freq),
        .out_valid(frequency_valid), .out_ready(result_accept)
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
    fsm #(.W(2), .INITIAL_STATE(STATE_WAIT_SAMPLE_TICK)) fsm_u (
        .clk(clk_sys), .rst_n(rst_n), .stn(next_state), .stc(current_state)
    );
    always @(*)
    begin
        next_state = current_state;
        case (current_state)
            STATE_WAIT_SAMPLE_TICK:
                if (smp_tick_up) next_state = STATE_START_CONVERSION;
            STATE_START_CONVERSION:
                if (conversion_valid) next_state = STATE_WAIT_AUDIO_ACCEPT;
            STATE_WAIT_AUDIO_ACCEPT:
                if (result_accept) next_state = smp_tick_up ? STATE_START_CONVERSION : STATE_WAIT_SAMPLE_TICK;
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
            for (voice = 0; voice < MAX_POLYPHONY; voice = voice + 1)
                latest_key_id_r[voice] <= '0;
            for (key_index = 0; key_index < KEY_NUM; key_index = key_index + 1)
                latest_pressure_r[key_index] <= 16'd0;
        end
        else
        begin
            if (smp_tick_up && !sample_ready) sample_overrun_r <= 1'b1;
            // 外层异步复位优先；内部判定不绕行公共 ready 的复位门控。
            if (smp_tick_up && sample_available)
            begin
                // 同沿交付旧帧时 event_valid 仍为高，必须排除已接收的旧结果。
                sample_has_frame_r <= event_valid && !event_ready;
                sample_on_r <= (event_valid && !event_ready) ? event_on : {MAX_POLYPHONY{1'b0}};
                sample_off_r <= (event_valid && !event_ready) ? event_off : {MAX_POLYPHONY{1'b0}};
                if (event_valid && !event_ready)
                begin
                    latest_occupied_r <= event_occupied;
                    latest_held_r <= event_held;
                    for (voice = 0; voice < MAX_POLYPHONY; voice = voice + 1)
                        latest_key_id_r[voice] <= event_key_id[voice];
                    for (key_index = 0; key_index < KEY_NUM; key_index = key_index + 1)
                        latest_pressure_r[key_index] <= event_pressure[key_index];
                end
            end
        end
    end
endmodule
