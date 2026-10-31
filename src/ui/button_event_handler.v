/**
 * 检测 B1～B4 的按下、松开和按住状态。
 * button_states: 已同步、消抖的状态，bit 0～3 对应 B1～B4。
 * button_pressed_event/button_released_event: 刚按下、刚松开。
 * button_held: 当前按住状态，用于判断 B4 微调。
 * 输入握手时更新历史；输出等待接收时保持不变。
 * NOTE: 复位后首次输入只记录状态，不产生按下或松开通知。
 */
module button_event_handler
(
    input clk_sys,
    input rst_n,
    input [3:0] button_states,
    input in_valid,
    output in_ready,
    output [3:0] button_pressed_event,
    output [3:0] button_released_event,
    output [3:0] button_held,
    output out_valid,
    input out_ready
);
    localparam STATE_WAIT_INPUT_FRAME = 1'b0;
    localparam STATE_WAIT_OUTPUT_ACCEPT = 1'b1;
    wire current_state;
    reg next_state;
    reg history_valid;
    reg [3:0] previous_states;
    reg [3:0] pressed_event_r;
    reg [3:0] released_event_r;
    reg [3:0] held_r;

    fsm #(
        .W(1),
        .INITIAL_STATE(STATE_WAIT_INPUT_FRAME)
    ) fsm_u (
        .clk(clk_sys), .rst_n(rst_n),
        .stn(next_state), .stc(current_state)
    );

    assign in_ready = rst_n && (current_state == STATE_WAIT_INPUT_FRAME);
    assign out_valid = rst_n && (current_state == STATE_WAIT_OUTPUT_ACCEPT);
    assign button_pressed_event = pressed_event_r;
    assign button_released_event = released_event_r;
    assign button_held = held_r;

    always @(*)
    begin
        next_state = current_state;
        case (current_state)
            STATE_WAIT_INPUT_FRAME:
                if (in_valid) next_state = STATE_WAIT_OUTPUT_ACCEPT;
            STATE_WAIT_OUTPUT_ACCEPT:
                if (out_ready) next_state = STATE_WAIT_INPUT_FRAME;
            default: next_state = STATE_WAIT_INPUT_FRAME;
        endcase
    end

    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            history_valid <= 1'b0;
            previous_states <= 4'd0;
            pressed_event_r <= 4'd0;
            released_event_r <= 4'd0;
            held_r <= 4'd0;
        end
        else if (in_valid && in_ready)
        begin
            pressed_event_r <= history_valid ? button_states & ~previous_states : 4'd0;
            released_event_r <= history_valid ? ~button_states & previous_states : 4'd0;
            held_r <= button_states;
            previous_states <= button_states;
            history_valid <= 1'b1;
        end
    end
endmodule
