/**
 * 键盘事件处理：判断琴键按下和松开，分配声部，并保存对应的压力。
 * key_states/key_velocity: 本次全部琴键的状态和压力，压力为 UQ0.16。
 * note_on/note_off: 各声部开始发声和开始释放的通知。
 * occupied/held: 声部已分配、对应琴键仍按住；frame_velocity 为本次保存的压力。
 * in_valid && in_ready 时接收；scan_tick_up 仅保留兼容，不决定接收时刻。
 * NOTE: out_ready 必须表示音符已交给音频模块，不能仅表示进入中间缓存。
 * NOTE: 相对 S1 增加压力及 occupied/held 接口；忙状态规则见声部分配模块。
 */
module keyboard_event_handler
#(
    parameter KEY_NUM = 24,  // 琴键数量，至少为 1
    parameter MAX_POLYPHONY = 32,  // 声部数量，默认 32
    parameter KEY_ID_WIDTH = (KEY_NUM > 1) ? $clog2(KEY_NUM) : 1  // 琴键编号位宽，至少为 1
)(
    input clk_sys,
    input rst_n,
    input scan_tick_up,
    input [KEY_NUM-1:0] key_states,
    input [15:0] key_velocity [KEY_NUM-1:0],
    input [MAX_POLYPHONY-1:0] note_busy,
    output [MAX_POLYPHONY-1:0] note_on,
    output [MAX_POLYPHONY-1:0] note_off,
    output [KEY_ID_WIDTH-1:0] key_id [MAX_POLYPHONY-1:0],
    output [MAX_POLYPHONY-1:0] occupied,
    output [MAX_POLYPHONY-1:0] held,
    output [15:0] frame_velocity [KEY_NUM-1:0],
    input out_ready,
    input in_valid,
    output out_valid,
    output in_ready
);
    reg frame_pending_r;
    reg [15:0] frame_velocity_r [KEY_NUM-1:0];
    wire frame_ready;
    wire event_valid;
    wire event_ready;
    wire [KEY_NUM-1:0] press_event;
    wire [KEY_NUM-1:0] release_event;
    integer key_index;
    genvar output_key;
    assign in_ready = rst_n && !frame_pending_r && frame_ready;
    generate
        for (output_key = 0; output_key < KEY_NUM; output_key = output_key + 1)
        begin : pressure_outputs
            assign frame_velocity[output_key] = frame_velocity_r[output_key];
        end
    endgenerate
    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            frame_pending_r <= 1'b0;
            for (key_index = 0; key_index < KEY_NUM; key_index = key_index + 1)
                frame_velocity_r[key_index] <= 16'd0;
        end
        else
        begin
            if (in_valid && in_ready)
            begin
                frame_pending_r <= 1'b1;
                for (key_index = 0; key_index < KEY_NUM; key_index = key_index + 1)
                    frame_velocity_r[key_index] <= key_velocity[key_index];
            end
            if (out_valid && out_ready) frame_pending_r <= 1'b0;
        end
    end
    keyboard_frame_events #(.KEY_NUM(KEY_NUM)) keyboard_frame_events_u (
        .clk(clk_sys), .rst_n(rst_n), .key_states(key_states),
        .in_valid(in_valid && !frame_pending_r), .in_ready(frame_ready),
        .press_event(press_event), .release_event(release_event), .frame_states(),
        .out_valid(event_valid), .out_ready(event_ready)
    );
    keyboard_voice_allocator #(
        .KEY_NUM(KEY_NUM), .MAX_POLYPHONY(MAX_POLYPHONY), .KEY_ID_WIDTH(KEY_ID_WIDTH)
    ) keyboard_voice_allocator_u (
        .clk_sys(clk_sys), .rst_n(rst_n), .press_event(press_event), .release_event(release_event),
        .note_busy(note_busy), .in_valid(event_valid), .in_ready(event_ready),
        .note_on(note_on), .note_off(note_off), .key_id(key_id), .occupied(occupied), .held(held),
        .out_valid(out_valid), .out_ready(out_ready)
    );
endmodule
