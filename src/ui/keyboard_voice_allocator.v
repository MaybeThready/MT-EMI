/**
 * 为新按下的琴键分配声部，松开时通知对应声部释放。
 * 先处理松开，再按键号递增处理按下；空闲声部优先选编号最小的。
 * 声部满时，先替换最早触发且已松开的音符，再替换最早触发且仍按住的音符。
 * occupied/held/key_id: 声部是否分配、琴键是否按住、对应键号。
 * out_ready: 本组音符已交给音频模块；等待时所有输出保持不变。
 * NOTE: 同一声部被新音替换时只发 note_on，音频端须重新起音。
 * TODO: note_busy 协议待确认；当前在交付时或之后观察到低→高→低，
 * 且琴键已松开，才允许下一次处理输入时回收。未满足时保留分配，但仍可替换。
 * 复位须与音频协调；此处不处理读取音色时的强制停音。
 */
module keyboard_voice_allocator
#(
    parameter KEY_NUM = 24,  // 琴键数量，至少为 1
    parameter MAX_POLYPHONY = 32,  // 声部数量，默认 32
    parameter KEY_ID_WIDTH = (KEY_NUM > 1) ? $clog2(KEY_NUM) : 1  // 琴键编号位宽，至少为 1
)(
    input clk_sys,
    input rst_n,
    input [KEY_NUM-1:0] press_event,
    input [KEY_NUM-1:0] release_event,
    input [MAX_POLYPHONY-1:0] note_busy,
    input in_valid,
    output in_ready,
    output [MAX_POLYPHONY-1:0] note_on,
    output [MAX_POLYPHONY-1:0] note_off,
    output [KEY_ID_WIDTH-1:0] key_id [MAX_POLYPHONY-1:0],
    output [MAX_POLYPHONY-1:0] occupied,
    output [MAX_POLYPHONY-1:0] held,
    output out_valid,
    input out_ready
);
    localparam VOICE_WIDTH = (MAX_POLYPHONY > 1) ? $clog2(MAX_POLYPHONY) : 1;
    localparam STATE_WAIT_EVENT_FRAME = 3'd0;
    localparam STATE_RELEASE_OLD_KEYS = 3'd1;
    localparam STATE_CHECK_NEXT_KEY = 3'd2;
    localparam STATE_SEARCH_VOICE = 3'd3;
    localparam STATE_ASSIGN_NEW_KEY = 3'd4;
    localparam STATE_CAPTURE_RESULT = 3'd5;
    localparam STATE_WAIT_AUDIO_ACCEPT = 3'd6;
    // 前一拍已经读取最后声部，当前状态只比较它，不能提前提交旧的胜者。
    localparam STATE_COMPARE_LAST_VOICE = 3'd7;
    wire [2:0] current_state;
    reg [2:0] next_state;
    reg [KEY_NUM-1:0] press_r;
    reg [KEY_NUM-1:0] release_r;
    reg [KEY_ID_WIDTH-1:0] key_index_r;
    reg [VOICE_WIDTH-1:0] voice_index_r;
    reg [VOICE_WIDTH-1:0] selected_voice_r;
    reg selected_valid_r;
    reg [1:0] selected_class_r;
    reg [VOICE_WIDTH-1:0] selected_age_r;
    reg [KEY_ID_WIDTH-1:0] owner_r [MAX_POLYPHONY-1:0];
    reg [VOICE_WIDTH-1:0] age_r [MAX_POLYPHONY-1:0];
    reg [MAX_POLYPHONY-1:0] allocated_r;
    reg [MAX_POLYPHONY-1:0] held_r;
    reg [MAX_POLYPHONY-1:0] delivered_r;
    reg [MAX_POLYPHONY-1:0] busy_low_seen_r;
    reg [MAX_POLYPHONY-1:0] busy_high_seen_r;
    reg [MAX_POLYPHONY-1:0] completed_r;
    reg [MAX_POLYPHONY-1:0] note_on_r;
    reg [MAX_POLYPHONY-1:0] note_off_r;
    reg [MAX_POLYPHONY-1:0] occupied_out_r;
    reg [MAX_POLYPHONY-1:0] held_out_r;
    reg [KEY_ID_WIDTH-1:0] key_id_out_r [MAX_POLYPHONY-1:0];
    reg [1:0] candidate_class;
    reg [1:0] candidate_class_r;
    reg [VOICE_WIDTH-1:0] candidate_age_r;
    reg [VOICE_WIDTH-1:0] candidate_voice_r;
    reg candidate_valid_r;
    integer voice;
    genvar output_voice;

    assign in_ready = rst_n && (current_state == STATE_WAIT_EVENT_FRAME);
    // 异步复位进入等待输入状态，valid 自然为零，避免复位网进入握手组合链。
    assign out_valid = (current_state == STATE_WAIT_AUDIO_ACCEPT);
    assign note_on = note_on_r;
    assign note_off = note_off_r;
    assign occupied = occupied_out_r;
    assign held = held_out_r;
    generate
        for (output_voice = 0; output_voice < MAX_POLYPHONY; output_voice = output_voice + 1)
        begin : voice_outputs
            assign key_id[output_voice] = key_id_out_r[output_voice];
        end
    endgenerate
    fsm #(.W(3), .INITIAL_STATE(STATE_WAIT_EVENT_FRAME)) fsm_u (
        .clk(clk_sys), .rst_n(rst_n), .stn(next_state), .stc(current_state)
    );

    // 第一级读取当前声部的优先级及年龄；第二级比较前一拍候选。
    // 读取多路器不再与年龄比较串联，仍保持每拍读取一个声部。
    always @(*)
    begin
        if (!allocated_r[voice_index_r] && !note_busy[voice_index_r])
            candidate_class = 2'd0;
        else if (allocated_r[voice_index_r] && !held_r[voice_index_r])
            candidate_class = 2'd1;
        else
            candidate_class = 2'd2;
    end

    always @(*)
    begin
        next_state = current_state;
        case (current_state)
            STATE_WAIT_EVENT_FRAME:
                if (in_valid) next_state = STATE_RELEASE_OLD_KEYS;
            STATE_RELEASE_OLD_KEYS:
                if (voice_index_r == MAX_POLYPHONY - 1) next_state = STATE_CHECK_NEXT_KEY;
            STATE_CHECK_NEXT_KEY:
                if (press_r[key_index_r]) next_state = STATE_SEARCH_VOICE;
                else if (key_index_r == KEY_NUM - 1) next_state = STATE_CAPTURE_RESULT;
            STATE_SEARCH_VOICE:
                if (voice_index_r == MAX_POLYPHONY - 1) next_state = STATE_COMPARE_LAST_VOICE;
            STATE_COMPARE_LAST_VOICE:
                next_state = STATE_ASSIGN_NEW_KEY;
            STATE_ASSIGN_NEW_KEY:
                next_state = (key_index_r == KEY_NUM - 1) ? STATE_CAPTURE_RESULT : STATE_CHECK_NEXT_KEY;
            STATE_CAPTURE_RESULT: next_state = STATE_WAIT_AUDIO_ACCEPT;
            STATE_WAIT_AUDIO_ACCEPT:
                if (out_ready) next_state = STATE_WAIT_EVENT_FRAME;
            default: next_state = STATE_WAIT_EVENT_FRAME;
        endcase
    end

    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            press_r <= '0;
            release_r <= '0;
            key_index_r <= '0;
            voice_index_r <= '0;
            selected_voice_r <= '0;
            selected_valid_r <= 1'b0;
            selected_class_r <= 2'd0;
            selected_age_r <= '0;
            candidate_class_r <= 2'd0;
            candidate_age_r <= '0;
            candidate_voice_r <= '0;
            candidate_valid_r <= 1'b0;
            allocated_r <= '0;
            held_r <= '0;
            delivered_r <= '0;
            busy_low_seen_r <= '0;
            busy_high_seen_r <= '0;
            completed_r <= '0;
            note_on_r <= '0;
            note_off_r <= '0;
            occupied_out_r <= '0;
            held_out_r <= '0;
            for (voice = 0; voice < MAX_POLYPHONY; voice = voice + 1)
            begin
                owner_r[voice] <= '0;
                age_r[voice] <= voice;
                key_id_out_r[voice] <= '0;
            end
        end
        else
        begin
            // 捕捉逐系统周期反馈；回收只在下一输入帧处理阶段修改映射。
            for (voice = 0; voice < MAX_POLYPHONY; voice = voice + 1)
            begin
                if (allocated_r[voice] && delivered_r[voice])
                begin
                    if (!note_busy[voice] && !busy_high_seen_r[voice])
                        busy_low_seen_r[voice] <= 1'b1;
                    if (note_busy[voice] && busy_low_seen_r[voice])
                        busy_high_seen_r[voice] <= 1'b1;
                    if (!note_busy[voice] && busy_high_seen_r[voice])
                        completed_r[voice] <= 1'b1;
                end
            end
            case (current_state)
                STATE_WAIT_EVENT_FRAME:
                begin
                    if (in_valid && in_ready)
                    begin
                        press_r <= press_event;
                        release_r <= release_event;
                        voice_index_r <= '0;
                        key_index_r <= '0;
                        note_on_r <= '0;
                        note_off_r <= '0;
                    end
                end
                STATE_RELEASE_OLD_KEYS:
                begin
                    // 静态展开各声部的松键判断，避免先选择 owner 再选择 release 的串联多路器。
                    // 仍然每拍只提交 voice_index_r 对应声部，回收和松键顺序不变。
                    for (voice = 0; voice < MAX_POLYPHONY; voice = voice + 1)
                    begin
                        if ((voice_index_r == voice) && allocated_r[voice])
                        begin
                            if (!held_r[voice] && completed_r[voice])
                                allocated_r[voice] <= 1'b0;
                            if (held_r[voice] && release_r[owner_r[voice]])
                            begin
                                held_r[voice] <= 1'b0;
                                note_off_r[voice] <= 1'b1;
                            end
                        end
                    end
                    if (voice_index_r != MAX_POLYPHONY - 1)
                        voice_index_r <= voice_index_r + 1'b1;
                end
                STATE_CHECK_NEXT_KEY:
                begin
                    if (press_r[key_index_r])
                    begin
                        voice_index_r <= '0;
                        selected_valid_r <= 1'b0;
                        candidate_valid_r <= 1'b0;
                    end
                    else if (key_index_r != KEY_NUM - 1)
                        key_index_r <= key_index_r + 1'b1;
                end
                STATE_SEARCH_VOICE, STATE_COMPARE_LAST_VOICE:
                begin
                    // 流水初拍没有候选；末尾排空时仍比较最后一项，包括 P=1。
                    if (candidate_valid_r && (!selected_valid_r ||
                        (candidate_class_r < selected_class_r) ||
                        ((candidate_class_r == selected_class_r) && (candidate_class_r != 2'd0) &&
                         (candidate_age_r > selected_age_r))))
                    begin
                        selected_voice_r <= candidate_voice_r;
                        selected_age_r <= candidate_age_r;
                        selected_class_r <= candidate_class_r;
                        selected_valid_r <= 1'b1;
                    end
                    if (current_state == STATE_SEARCH_VOICE)
                    begin
                        candidate_voice_r <= voice_index_r;
                        candidate_age_r <= age_r[voice_index_r];
                        candidate_class_r <= candidate_class;
                        candidate_valid_r <= 1'b1;
                        if (voice_index_r != MAX_POLYPHONY - 1)
                            voice_index_r <= voice_index_r + 1'b1;
                    end
                end
                STATE_ASSIGN_NEW_KEY:
                begin
                    owner_r[selected_voice_r] <= key_index_r;
                    allocated_r[selected_voice_r] <= 1'b1;
                    held_r[selected_voice_r] <= 1'b1;
                    delivered_r[selected_voice_r] <= 1'b0;
                    busy_low_seen_r[selected_voice_r] <= 1'b0;
                    busy_high_seen_r[selected_voice_r] <= 1'b0;
                    completed_r[selected_voice_r] <= 1'b0;
                    note_on_r[selected_voice_r] <= 1'b1;
                    note_off_r[selected_voice_r] <= 1'b0;
                    // 年龄为 0..P-1 的排列，0 最新；移动到队首不会溢出。
                    // 搜索已同步保存胜出声部的年龄，搜索到提交之间年龄表不变。
                    // 复用 selected_age_r，省去重新读取 age_r[selected_voice_r] 的多路器。
                    for (voice = 0; voice < MAX_POLYPHONY; voice = voice + 1)
                    begin
                        if (selected_voice_r == voice)
                            age_r[voice] <= '0;
                        else if (age_r[voice] < selected_age_r)
                            age_r[voice] <= age_r[voice] + 1'b1;
                    end
                    if (key_index_r != KEY_NUM - 1)
                        key_index_r <= key_index_r + 1'b1;
                end
                STATE_CAPTURE_RESULT:
                begin
                    occupied_out_r <= allocated_r;
                    held_out_r <= held_r;
                    for (voice = 0; voice < MAX_POLYPHONY; voice = voice + 1)
                        key_id_out_r[voice] <= owner_r[voice];
                end
                STATE_WAIT_AUDIO_ACCEPT:
                begin
                    if (out_valid && out_ready)
                    begin
                        for (voice = 0; voice < MAX_POLYPHONY; voice = voice + 1)
                        begin
                            if (note_on_r[voice])
                            begin
                                delivered_r[voice] <= 1'b1;
                                busy_low_seen_r[voice] <= !note_busy[voice];
                                busy_high_seen_r[voice] <= 1'b0;
                                completed_r[voice] <= 1'b0;
                            end
                        end
                        note_on_r <= '0;
                        note_off_r <= '0;
                    end
                end
                default:
                begin
                    note_on_r <= '0;
                    note_off_r <= '0;
                end
            endcase
        end
    end
    // synthesis translate_off
    initial
    begin
        if ((KEY_NUM < 1) || (MAX_POLYPHONY < 1) ||
            (KEY_ID_WIDTH < ((KEY_NUM > 1) ? $clog2(KEY_NUM) : 1)))
            $fatal(1, "非法键盘数量或索引位宽");
    end
    // synthesis translate_on
endmodule
