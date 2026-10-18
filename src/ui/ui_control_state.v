/**
 * 根据按钮动作设置演奏模式、粗细调及是否允许旋钮编辑。
 * mode: 模式 0/1；fine_adjust: 演奏界面按住 B4 时微调。
 * edit_enable: 演奏界面允许编辑；edit_target 当前固定为通道 0。
 * context_valid/context_ready: 交付本次按钮处理后的模式和编辑设置。
 * B1 进入菜单优先于 B2 切换模式；菜单中 B4 返回，返回时不同时切换模式。
 * TODO: 仅实现菜单进出，未实现菜单选项、音色存取和模式 2。
 */
module ui_control_state
(
    input clk_sys,
    input rst_n,
    input [3:0] button_pressed_event,
    input [3:0] button_released_event,
    input [3:0] button_held,
    input in_valid,
    output in_ready,
    output [1:0] mode,
    output fine_adjust,
    output edit_enable,
    output edit_target,
    output clear_wave_progress,
    output context_valid,
    input context_ready
);
    localparam STATE_WAIT_BUTTON_EVENT = 1'b0;
    localparam STATE_WAIT_CONTEXT_ACCEPT = 1'b1;
    wire current_state;
    reg next_state;
    reg [1:0] mode_r;
    reg menu_active_r;
    reg fine_adjust_r;
    reg clear_wave_progress_r;

    fsm #(
        .W(1), .INITIAL_STATE(STATE_WAIT_BUTTON_EVENT)
    ) fsm_u (
        .clk(clk_sys), .rst_n(rst_n),
        .stn(next_state), .stc(current_state)
    );
    assign in_ready = rst_n && (current_state == STATE_WAIT_BUTTON_EVENT);
    assign context_valid = rst_n && (current_state == STATE_WAIT_CONTEXT_ACCEPT);
    assign mode = mode_r;
    assign fine_adjust = fine_adjust_r;
    assign edit_enable = !menu_active_r;
    assign edit_target = 1'b0;
    assign clear_wave_progress = clear_wave_progress_r;

    always @(*)
    begin
        next_state = current_state;
        case (current_state)
            STATE_WAIT_BUTTON_EVENT:
                if (in_valid) next_state = STATE_WAIT_CONTEXT_ACCEPT;
            STATE_WAIT_CONTEXT_ACCEPT:
                if (context_ready) next_state = STATE_WAIT_BUTTON_EVENT;
            default: next_state = STATE_WAIT_BUTTON_EVENT;
        endcase
    end

    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            mode_r <= 2'd0;
            menu_active_r <= 1'b0;
            fine_adjust_r <= 1'b0;
            clear_wave_progress_r <= 1'b0;
        end
        else if (in_valid && in_ready)
        begin
            clear_wave_progress_r <= 1'b0;
            fine_adjust_r <= 1'b0;
            if (menu_active_r)
            begin
                if (button_pressed_event[3])
                begin
                    menu_active_r <= 1'b0;
                    fine_adjust_r <= button_held[3];
                    clear_wave_progress_r <= 1'b1;
                end
            end
            else if (button_pressed_event[0])
            begin
                menu_active_r <= 1'b1;
                clear_wave_progress_r <= 1'b1;
            end
            else
            begin
                fine_adjust_r <= button_held[3];
                if (button_pressed_event[1])
                begin
                    mode_r <= (mode_r == 2'd0) ? 2'd1 : 2'd0;
                    clear_wave_progress_r <= 1'b1;
                end
            end
        end
    end
    // NOTE: 接口保留松开事件；B4 微调由持续按住状态控制。
endmodule
