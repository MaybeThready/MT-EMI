/**
 * 协调按钮和旋钮的处理顺序，避免切换模式时用错旋钮步长。
 * 先处理按钮并保存模式和粗细调设置，再逐组处理对应的旋钮动作。
 * button_batch_id/knob_batch_id: 同批编号；BATCH_ID_WIDTH 为编号位宽。
 * 按钮每批一组且 last=1；旋钮每批至少一组，最后一组 last=1。
 * context_valid: 按钮设置已算好；frame_done_valid: 本组旋钮已处理完。
 * 编号从零开始并按位宽回绕；clear_wave_progress 只用于本批第一组旋钮。
 * NOTE: 编号不匹配时置 protocol_error 并停止，须与输入端一起复位恢复。
 * TODO: 缺少输入或结束标志时没有超时恢复；公开顶层只发送每批一组旋钮。
 */
module ui_input_frame_joiner
#(
    parameter BATCH_ID_WIDTH = 32  // 按钮和旋钮配对编号的位宽
)(
    input clk_sys,
    input rst_n,
    input [3:0] button_states,
    input [BATCH_ID_WIDTH-1:0] button_batch_id,
    input button_batch_last,
    input button_in_valid,
    output button_in_ready,
    input [7:0] knob_states,
    input [7:0] knob_dirs,
    input [7:0] knob_pressed,
    input [BATCH_ID_WIDTH-1:0] knob_batch_id,
    input knob_batch_last,
    input knob_in_valid,
    output knob_in_ready,
    output [3:0] handler_button_states,
    output button_out_valid,
    input button_out_ready,
    input [1:0] context_mode,
    input context_fine_adjust,
    input context_edit_enable,
    input context_edit_target,
    input context_clear_wave_progress,
    input context_valid,
    output context_ready,
    output [7:0] handler_knob_states,
    output [7:0] handler_knob_dirs,
    output [7:0] handler_knob_pressed,
    output knob_out_valid,
    input knob_out_ready,
    output [1:0] mode,
    output fine_adjust,
    output edit_enable,
    output edit_target,
    output clear_wave_progress,
    input frame_done_valid,
    output frame_done_ready,
    output protocol_error
);
    // 各 WAIT 状态名称明确指出当前尚未完成的接收或应答。
    localparam STATE_WAIT_BATCH_INPUTS = 3'd0;
    localparam STATE_SEND_BUTTON_FRAME = 3'd1;
    localparam STATE_WAIT_CONTROL_CONTEXT = 3'd2;
    localparam STATE_WAIT_KNOB_FRAME = 3'd3;
    localparam STATE_SEND_KNOB_FRAME = 3'd4;
    localparam STATE_WAIT_FRAME_COMMIT = 3'd5;
    localparam STATE_PROTOCOL_ERROR = 3'd6;
    wire [2:0] current_state;
    reg [2:0] next_state;
    reg [BATCH_ID_WIDTH-1:0] expected_batch_id;
    reg button_buffer_full;
    reg [3:0] button_states_r;
    reg [BATCH_ID_WIDTH-1:0] button_batch_id_r;
    reg button_batch_last_r;
    reg knob_buffer_full;
    reg [7:0] knob_states_r;
    reg [7:0] knob_dirs_r;
    reg [7:0] knob_pressed_r;
    reg [BATCH_ID_WIDTH-1:0] knob_batch_id_r;
    reg knob_batch_last_r;
    reg in_flight_last;
    reg first_frame_r;
    reg [1:0] mode_r;
    reg fine_adjust_r;
    reg edit_enable_r;
    reg edit_target_r;
    reg batch_clear_r;

    fsm #(
        .W(3), .INITIAL_STATE(STATE_WAIT_BATCH_INPUTS)
    ) fsm_u (
        .clk(clk_sys), .rst_n(rst_n), .stn(next_state), .stc(current_state)
    );
    assign protocol_error = current_state == STATE_PROTOCOL_ERROR;
    assign button_in_ready = rst_n && !protocol_error && !button_buffer_full;
    assign knob_in_ready = rst_n && !protocol_error && !knob_buffer_full;
    assign button_out_valid = rst_n && (current_state == STATE_SEND_BUTTON_FRAME);
    assign knob_out_valid = rst_n && (current_state == STATE_SEND_KNOB_FRAME);
    assign context_ready = rst_n && (current_state == STATE_WAIT_CONTROL_CONTEXT);
    assign frame_done_ready = rst_n && (current_state == STATE_WAIT_FRAME_COMMIT);
    assign handler_button_states = button_states_r;
    assign handler_knob_states = knob_states_r;
    assign handler_knob_dirs = knob_dirs_r;
    assign handler_knob_pressed = knob_pressed_r;
    assign mode = mode_r;
    assign fine_adjust = fine_adjust_r;
    assign edit_enable = edit_enable_r;
    assign edit_target = edit_target_r;
    assign clear_wave_progress = batch_clear_r && first_frame_r;

    always @(*)
    begin
        next_state = current_state;
        case (current_state)
            STATE_WAIT_BATCH_INPUTS:
            begin
                if ((button_buffer_full && ((button_batch_id_r != expected_batch_id) || !button_batch_last_r)) ||
                    (knob_buffer_full && (knob_batch_id_r != expected_batch_id)))
                    next_state = STATE_PROTOCOL_ERROR;
                else if (button_buffer_full && knob_buffer_full)
                    next_state = STATE_SEND_BUTTON_FRAME;
            end
            STATE_SEND_BUTTON_FRAME:
                if (button_out_ready) next_state = STATE_WAIT_CONTROL_CONTEXT;
            STATE_WAIT_CONTROL_CONTEXT:
                if (context_valid) next_state = STATE_WAIT_KNOB_FRAME;
            STATE_WAIT_KNOB_FRAME:
            begin
                if (knob_buffer_full)
                begin
                    if (knob_batch_id_r != expected_batch_id) next_state = STATE_PROTOCOL_ERROR;
                    else next_state = STATE_SEND_KNOB_FRAME;
                end
            end
            STATE_SEND_KNOB_FRAME:
                if (knob_out_ready) next_state = STATE_WAIT_FRAME_COMMIT;
            STATE_WAIT_FRAME_COMMIT:
            begin
                if (frame_done_valid)
                begin
                    if (in_flight_last) next_state = STATE_WAIT_BATCH_INPUTS;
                    else next_state = STATE_WAIT_KNOB_FRAME;
                end
            end
            STATE_PROTOCOL_ERROR: next_state = STATE_PROTOCOL_ERROR;
            default: next_state = STATE_PROTOCOL_ERROR;
        endcase
    end

    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            expected_batch_id <= {BATCH_ID_WIDTH{1'b0}};
            button_buffer_full <= 1'b0;
            button_states_r <= 4'd0;
            button_batch_id_r <= {BATCH_ID_WIDTH{1'b0}};
            button_batch_last_r <= 1'b0;
            knob_buffer_full <= 1'b0;
            knob_states_r <= 8'd0;
            knob_dirs_r <= 8'd0;
            knob_pressed_r <= 8'd0;
            knob_batch_id_r <= {BATCH_ID_WIDTH{1'b0}};
            knob_batch_last_r <= 1'b0;
            in_flight_last <= 1'b0;
            first_frame_r <= 1'b1;
            mode_r <= 2'd0;
            fine_adjust_r <= 1'b0;
            edit_enable_r <= 1'b0;
            edit_target_r <= 1'b0;
            batch_clear_r <= 1'b0;
        end
        else
        begin
            if (button_in_valid && button_in_ready)
            begin
                button_buffer_full <= 1'b1;
                button_states_r <= button_states;
                button_batch_id_r <= button_batch_id;
                button_batch_last_r <= button_batch_last;
            end
            if (button_out_valid && button_out_ready) button_buffer_full <= 1'b0;
            if (knob_in_valid && knob_in_ready)
            begin
                knob_buffer_full <= 1'b1;
                knob_states_r <= knob_states;
                knob_dirs_r <= knob_dirs;
                knob_pressed_r <= knob_pressed;
                knob_batch_id_r <= knob_batch_id;
                knob_batch_last_r <= knob_batch_last;
            end
            if (knob_out_valid && knob_out_ready)
            begin
                knob_buffer_full <= 1'b0;
                in_flight_last <= knob_batch_last_r;
            end
            if (context_valid && context_ready)
            begin
                mode_r <= context_mode;
                fine_adjust_r <= context_fine_adjust;
                edit_enable_r <= context_edit_enable;
                edit_target_r <= context_edit_target;
                batch_clear_r <= context_clear_wave_progress;
                first_frame_r <= 1'b1;
            end
            // first_frame 保持到参数存储提交完成；
            // 若在事件处理输入握手时就清除，会丢失清除余量命令。
            if (frame_done_valid && frame_done_ready)
            begin
                first_frame_r <= 1'b0;
                if (in_flight_last) expected_batch_id <= expected_batch_id + 1'b1;
            end
        end
    end
endmodule
