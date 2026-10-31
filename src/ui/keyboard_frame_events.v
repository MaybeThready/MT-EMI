/**
 * 比较前后两次琴键状态，输出刚按下和刚松开的琴键。
 * key_states: 驱动已同步、消抖的全部琴键状态，1 表示按住。
 * press_event/release_event: 刚按下、刚松开；frame_states 为本次状态。
 * 只在输入握手时更新历史；持续按住不重复触发，无变化也输出一组结果。
 * 接收后的下一周期输出有效；等待接收时保持数据，不能按高电平重复处理。
 * NOTE: 复位后历史为全松开，首次输入中按住的琴键会产生按下通知。
 */
module keyboard_frame_events
#(
    parameter KEY_NUM = 24  // 琴键数量，至少为 1
)(
    input clk,
    input rst_n,
    input [KEY_NUM-1:0] key_states,
    input in_valid,
    output in_ready,
    output [KEY_NUM-1:0] press_event,
    output [KEY_NUM-1:0] release_event,
    output [KEY_NUM-1:0] frame_states,
    output out_valid,
    input out_ready
);
    // 缓冲为空：in_ready=1、out_valid=0；只在输入握手沿采样并计算事件。
    localparam STATE_WAIT_INPUT_FRAME = 1'b0;
    // 缓冲已有完整事件帧：in_ready=0、out_valid=1；保持数据直到输出握手。
    localparam STATE_WAIT_OUTPUT_ACCEPT = 1'b1;

    wire [0:0] current_state;  // 当前周期实际执行的状态
    reg [0:0] next_state;  // 下一上升沿将进入的状态
    reg [KEY_NUM-1:0] previous_key_states_r;
    reg [KEY_NUM-1:0] press_event_r;
    reg [KEY_NUM-1:0] release_event_r;
    reg [KEY_NUM-1:0] frame_states_r;

    // 状态寄存复用正式项目模块；不修改 src/common/fsm.v。
    fsm #(
        .W(1),
        .INITIAL_STATE(STATE_WAIT_INPUT_FRAME)
    ) fsm_u (
        .clk(clk),
        .rst_n(rst_n),
        .stn(next_state),
        .stc(current_state)
    );

    // 组合状态转移。计算的是下一状态；时序动作仍由 current_state 决定。
    // 接收沿同时写入事件寄存器并进入等待交付状态，因此下一周期才有效。
    always @(*)
    begin
        case (current_state)
            STATE_WAIT_INPUT_FRAME: next_state = in_valid ? STATE_WAIT_OUTPUT_ACCEPT : STATE_WAIT_INPUT_FRAME;
            STATE_WAIT_OUTPUT_ACCEPT: next_state = out_ready ? STATE_WAIT_INPUT_FRAME : STATE_WAIT_OUTPUT_ACCEPT;
            default: next_state = STATE_WAIT_INPUT_FRAME;
        endcase
    end

    // 时序数据输出：只在完整输入帧握手时更新历史状态。
    always @(posedge clk or negedge rst_n)
    begin
        if (!rst_n)
        begin
            previous_key_states_r <= {KEY_NUM{1'b0}};
            press_event_r <= {KEY_NUM{1'b0}};
            release_event_r <= {KEY_NUM{1'b0}};
            frame_states_r <= {KEY_NUM{1'b0}};
        end
        else
        begin
            case (current_state)
                STATE_WAIT_INPUT_FRAME:
                begin
                    if (in_valid && in_ready)
                    begin
                        press_event_r <= key_states & ~previous_key_states_r;
                        release_event_r <= ~key_states & previous_key_states_r;
                        frame_states_r <= key_states;
                        previous_key_states_r <= key_states;
                    end
                end

                STATE_WAIT_OUTPUT_ACCEPT:
                begin
                    if (out_valid && out_ready)
                    begin
                        press_event_r <= {KEY_NUM{1'b0}};
                        release_event_r <= {KEY_NUM{1'b0}};
                    end
                end

                default:
                begin
                    previous_key_states_r <= {KEY_NUM{1'b0}};
                    press_event_r <= {KEY_NUM{1'b0}};
                    release_event_r <= {KEY_NUM{1'b0}};
                    frame_states_r <= {KEY_NUM{1'b0}};
                end
            endcase
        end
    end

    assign in_ready = rst_n && (current_state == STATE_WAIT_INPUT_FRAME);
    assign out_valid = rst_n && (current_state == STATE_WAIT_OUTPUT_ACCEPT);
    assign press_event = press_event_r;
    assign release_event = release_event_r;
    assign frame_states = frame_states_r;

    // synthesis translate_off
    initial
    begin
        if (KEY_NUM < 1)
            $fatal(1, "KEY_NUM must be at least 1");
    end
    // synthesis translate_on
endmodule
