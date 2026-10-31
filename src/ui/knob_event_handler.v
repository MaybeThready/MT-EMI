/**
 * 旋钮事件模块 v2：处理旋钮转动和按压，输出本次增减步数及刚按下的旋钮。
 * v2 版本修改：去掉接收判断和输出 valid 的重复复位门控，保留异步复位。
 * knob_states: 1 表示本次转动一步；knob_dirs: 1 增加、0 减少。
 * knob_pressed: 按住状态；knob_pressed_event: 刚按下的通知。
 * knob_delta: 有符号 2 位整数，-1/0/+1 步，不是累计参数值。
 * 输入握手时接收；输出等待接收时保持；scan_tick_up 仅保留兼容。
 * NOTE: 相对 S1，用 knob_delta 替代 knob_value，参数累计交给参数设置模块。
 * NOTE: 首次输入不产生按压通知，但正常处理转动；同时按压和转动均报告。
 * TODO: 一步对应多少 AB 变化须与驱动确认；不能直接输入持续旋转电平。
 */
module knob_event_handler
#(
    parameter KNOB_NUM = 8  // 旋钮数量；完整 UI 当前使用 8 个
)(
    input clk_sys,
    input rst_n,
    input scan_tick_up,
    input [KNOB_NUM-1:0] knob_states,
    input [KNOB_NUM-1:0] knob_dirs,
    input [KNOB_NUM-1:0] knob_pressed,
    output signed [1:0] knob_delta [KNOB_NUM-1:0],
    output [KNOB_NUM-1:0] knob_pressed_event,
    input out_ready,
    input in_valid,
    output out_valid,
    output in_ready
);
    // 槽位为空：可以接收完整输入帧，没有待交付输出。
    localparam STATE_WAIT_INPUT_FRAME = 1'b0;
    // 槽位有数据：只等待下游接收，禁止接收下一帧和修改历史。
    localparam STATE_WAIT_OUTPUT_ACCEPT = 1'b1;

    wire [0:0] current_state;
    reg [0:0] next_state;
    reg history_valid_r;
    reg [KNOB_NUM-1:0] previous_pressed_r;
    reg [KNOB_NUM-1:0] knob_pressed_event_r;
    reg signed [1:0] knob_delta_r [KNOB_NUM-1:0];
    integer lane;

    // 三段式的状态寄存段：只读引用正式公共模块。
    fsm #(
        .W(1),
        .INITIAL_STATE(STATE_WAIT_INPUT_FRAME)
    ) fsm_u (
        .clk(clk_sys),
        .rst_n(rst_n),
        .stn(next_state),
        .stc(current_state)
    );

    // 组合转移：不要求 tick 同拍，也不等待下游 ready 才形成有效输出。
    always @(*)
    begin
        case (current_state)
            STATE_WAIT_INPUT_FRAME: next_state = in_valid ? STATE_WAIT_OUTPUT_ACCEPT : STATE_WAIT_INPUT_FRAME;
            STATE_WAIT_OUTPUT_ACCEPT: next_state = out_ready ? STATE_WAIT_INPUT_FRAME : STATE_WAIT_OUTPUT_ACCEPT;
            default: next_state = STATE_WAIT_INPUT_FRAME;
        endcase
    end

    // 时序输出：帧历史只在接收沿改变，不能用逐周期边沿检测器替代。
    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            history_valid_r <= 1'b0;
            previous_pressed_r <= {KNOB_NUM{1'b0}};
            knob_pressed_event_r <= {KNOB_NUM{1'b0}};
            for (lane = 0; lane < KNOB_NUM; lane = lane + 1)
                knob_delta_r[lane] <= 2'sd0;
        end
        else
        begin
            case (current_state)
                STATE_WAIT_INPUT_FRAME:
                begin
                    // 已在非复位的等待输入分支，等价于本拍输入握手。
                    if (in_valid)
                    begin
                        history_valid_r <= 1'b1;
                        previous_pressed_r <= knob_pressed;
                        knob_pressed_event_r <= history_valid_r ?
                            (knob_pressed & ~previous_pressed_r) : {KNOB_NUM{1'b0}};
                        for (lane = 0; lane < KNOB_NUM; lane = lane + 1)
                        begin
                            if (!knob_states[lane])
                                knob_delta_r[lane] <= 2'sd0;
                            else if (knob_dirs[lane])
                                knob_delta_r[lane] <= 2'sd1;
                            else
                                knob_delta_r[lane] <= -2'sd1;
                        end
                    end
                end

                STATE_WAIT_OUTPUT_ACCEPT:
                begin
                    // 有意保持数据；接收后 out_valid 随状态清零。
                    // 下一个输入握手才覆盖槽位，invalid 时数据无业务含义。
                end

                default:
                begin
                    history_valid_r <= 1'b0;
                    previous_pressed_r <= {KNOB_NUM{1'b0}};
                    knob_pressed_event_r <= {KNOB_NUM{1'b0}};
                    for (lane = 0; lane < KNOB_NUM; lane = lane + 1)
                        knob_delta_r[lane] <= 2'sd0;
                end
            endcase
        end
    end

    assign in_ready = rst_n && (current_state == STATE_WAIT_INPUT_FRAME);
    // 状态机异步复位到等待输入，复位期间不会保持输出有效。
    assign out_valid = (current_state == STATE_WAIT_OUTPUT_ACCEPT);
    assign knob_pressed_event = knob_pressed_event_r;

    genvar output_lane;
    generate
        for (output_lane = 0; output_lane < KNOB_NUM; output_lane = output_lane + 1)
        begin : generate_delta_outputs
            assign knob_delta[output_lane] = knob_delta_r[output_lane];
        end
    endgenerate

    // synthesis translate_off
    initial
    begin
        if (KNOB_NUM < 1)
            $fatal(1, "KNOB_NUM must be at least 1");
    end
    // synthesis translate_on
endmodule
