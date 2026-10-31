/**
 * 按钮控制模块 v3：设置演奏模式、微调、菜单及音色读写命令。
 * v3 版本修改：音色命令 valid 直接使用异步清零寄存器，去掉重复复位门控。
 * mode: 演奏模式0/1，高级模式2；fine_adjust: 演奏界面按住 B4 时微调。
 * edit_enable: 演奏页及高级参数调整项允许编辑；edit_target 当前固定为通道 0。
 * context_valid/context_ready: 交付本次按钮处理后的模式和编辑设置。
 * B1 进入菜单优先于 B2 切换模式；菜单中 B4 返回，返回时不同时切换模式。
 * menu_page: 0 演奏、1 主菜单、2 槽位、3 确认、4 执行中、5 结果、6 效果目录、7 高级编辑。
 * menu_selection: 主菜单 0～3；menu_slot: 0～15；menu_save=1 保存、=0 读取。
 * 保存确认页始终提示“将覆盖所选槽位”；空槽信息由未来存储目录提供。
 * B4 取消优先；B2/B3 上一项/下一项，到端点保持。执行中忽略按钮动作。
 * NOTE: 模式2为高级编辑，K1/K2调参数；B2/B3选调整/恢复项，B1确认恢复，B4返回。
 * 主菜单编码0演奏/1读取/2保存/3高级，页面6效果目录/7编辑；退出恢复原模式0/1。
 * 清音仍未实现。
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
    input context_ready,
    output preset_command_valid,
    input preset_command_ready,
    output preset_command_write,
    output [3:0] preset_command_slot,
    input preset_result_valid,
    output preset_result_ready,
    input [3:0] preset_result_status,
    output [1:0] effect_select,  // 0混响、1延迟、2失真、3合唱；随context握手
    output effect_reset,  // 本批恢复所选效果两参数及干湿比，仅消费一次
    output menu_effect_reset,  // 编辑页当前选中恢复默认项
    output [2:0] menu_page,
    output [1:0] menu_selection,
    output [3:0] menu_slot,
    output menu_save,
    output [3:0] menu_result_status
);
    localparam STATE_WAIT_BUTTON_EVENT = 1'b0;
    localparam STATE_WAIT_CONTEXT_ACCEPT = 1'b1;
    wire current_state;
    reg next_state;
    reg [1:0] mode_r;
    localparam PAGE_PLAY = 3'd0;
    localparam PAGE_MAIN_MENU = 3'd1;
    localparam PAGE_SELECT_SLOT = 3'd2;
    localparam PAGE_CONFIRM = 3'd3;
    localparam PAGE_WAIT_OPERATION = 3'd4;
    localparam PAGE_SHOW_RESULT = 3'd5;
    localparam PAGE_EFFECT_LIST = 3'd6;
    localparam PAGE_EFFECT_EDIT = 3'd7;
    reg [1:0] effect_select_r;
    reg effect_reset_r;
    reg menu_effect_reset_r;
    assign effect_select = effect_select_r;
    assign effect_reset = effect_reset_r;
    assign menu_effect_reset = menu_effect_reset_r;
    wire [2:0] menu_page_r;
    reg [2:0] menu_page_next;
    reg [1:0] menu_selection_r;
    reg [3:0] menu_slot_r;
    reg menu_save_r;
    reg [3:0] menu_result_status_r;
    reg command_valid_r;
    wire menu_active_r;
    assign menu_active_r = (menu_page_r != PAGE_PLAY);
    assign menu_page = menu_page_r;
    assign menu_selection = menu_selection_r;
    assign menu_slot = menu_slot_r;
    assign menu_save = menu_save_r;
    assign menu_result_status = menu_result_status_r;
    // command_valid_r 在复位时异步清零，不再把复位串入下游参数装载条件。
    assign preset_command_valid = command_valid_r;
    assign preset_command_write = menu_save_r;
    assign preset_command_slot = menu_slot_r;
    assign preset_result_ready = rst_n && (menu_page_r == PAGE_WAIT_OPERATION) && !command_valid_r;
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
    assign mode = ((menu_page_r == PAGE_EFFECT_LIST) || (menu_page_r == PAGE_EFFECT_EDIT)) ? 2'd2 : mode_r;
    assign fine_adjust = fine_adjust_r;
    assign edit_enable = !menu_active_r || ((menu_page_r == PAGE_EFFECT_EDIT) && !menu_effect_reset_r);
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


    fsm #(.W(3), .INITIAL_STATE(PAGE_PLAY)) menu_fsm_u (
        .clk(clk_sys), .rst_n(rst_n), .stn(menu_page_next), .stc(menu_page_r)
    );
    always @(*)
    begin
        menu_page_next = menu_page_r;
        if ((menu_page_r == PAGE_WAIT_OPERATION) && preset_result_valid && preset_result_ready)
            menu_page_next = PAGE_SHOW_RESULT;
        else if (in_valid && in_ready)
        begin
            case (menu_page_r)
                PAGE_PLAY:
                    if (button_pressed_event[0]) menu_page_next = PAGE_MAIN_MENU;
                PAGE_MAIN_MENU:
                begin
                    if (button_pressed_event[3] || (button_pressed_event[0] && menu_selection_r == 2'd0))
                        menu_page_next = PAGE_PLAY;
                    else if (button_pressed_event[0])
                        menu_page_next = (menu_selection_r == 2'd3) ? PAGE_EFFECT_LIST : PAGE_SELECT_SLOT;
                end
                PAGE_SELECT_SLOT:
                    if (button_pressed_event[3]) menu_page_next = PAGE_MAIN_MENU;
                    else if (button_pressed_event[0]) menu_page_next = PAGE_CONFIRM;
                PAGE_CONFIRM:
                    if (button_pressed_event[3]) menu_page_next = PAGE_SELECT_SLOT;
                    else if (button_pressed_event[0]) menu_page_next = PAGE_WAIT_OPERATION;
                PAGE_SHOW_RESULT:
                    if (button_pressed_event[0] || button_pressed_event[3]) menu_page_next = PAGE_SELECT_SLOT;
                PAGE_EFFECT_LIST:
                    if (button_pressed_event[3]) menu_page_next = PAGE_MAIN_MENU;
                    else if (button_pressed_event[0]) menu_page_next = PAGE_EFFECT_EDIT;
                PAGE_EFFECT_EDIT:
                    if (button_pressed_event[3]) menu_page_next = PAGE_EFFECT_LIST;
                default:
                begin
                    // 执行中保持，只有收到结果才退出。
                end
            endcase
        end
    end

    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            mode_r <= 2'd0;
            effect_select_r <= 2'd0;
            effect_reset_r <= 1'b0;
            menu_effect_reset_r <= 1'b0;
            fine_adjust_r <= 1'b0;
            clear_wave_progress_r <= 1'b0;
            menu_selection_r <= 2'd0;
            menu_slot_r <= 4'd0;
            menu_save_r <= 1'b1;
            menu_result_status_r <= 4'd0;
            command_valid_r <= 1'b0;
        end
        else
        begin
            if (preset_command_valid && preset_command_ready) command_valid_r <= 1'b0;
            if (preset_result_valid && preset_result_ready)
            begin
                menu_result_status_r <= preset_result_status;
            end
            if (in_valid && in_ready)
            begin
                clear_wave_progress_r <= 1'b0;
                effect_reset_r <= 1'b0;
                fine_adjust_r <= 1'b0;
                case (menu_page_r)
                    PAGE_PLAY:
                    begin
                        if (button_pressed_event[0])
                        begin
                            menu_selection_r <= 2'd0;
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
                    PAGE_MAIN_MENU:
                    begin
                        if (button_pressed_event[3] || (button_pressed_event[0] && menu_selection_r == 2'd0))
                        begin
                            fine_adjust_r <= button_held[3];
                            clear_wave_progress_r <= 1'b1;
                        end
                        else if (button_pressed_event[0])
                        begin
                            if (menu_selection_r != 2'd3)
                            begin
                                menu_save_r <= (menu_selection_r == 2'd2);
                            end
                        end
                        else if (button_pressed_event[1])
                        begin
                            if (menu_selection_r != 2'd0) menu_selection_r <= menu_selection_r - 2'd1;
                        end
                        else if (button_pressed_event[2] && menu_selection_r != 2'd3)
                            menu_selection_r <= menu_selection_r + 2'd1;
                    end
                    PAGE_EFFECT_LIST:
                    begin
                        clear_wave_progress_r <= 1'b1;
                        menu_effect_reset_r <= 1'b0;
                        if (!button_pressed_event[3] && !button_pressed_event[0])
                        begin
                            if (button_pressed_event[1] && effect_select_r != 2'd0)
                                effect_select_r <= effect_select_r - 2'd1;
                            else if (!button_pressed_event[1] && button_pressed_event[2] && effect_select_r != 2'd3)
                                effect_select_r <= effect_select_r + 2'd1;
                        end
                    end
                    PAGE_EFFECT_EDIT:
                    begin
                        if (button_pressed_event[3]) clear_wave_progress_r <= 1'b1;
                        else if (button_pressed_event[0] && menu_effect_reset_r) effect_reset_r <= 1'b1;
                        else if (button_pressed_event[1]) menu_effect_reset_r <= 1'b0;
                        else if (button_pressed_event[2]) menu_effect_reset_r <= 1'b1;
                    end
                    PAGE_SELECT_SLOT:
                    begin
                        if (!button_pressed_event[3] && !button_pressed_event[0])
                        begin
                            if (button_pressed_event[1])
                            begin
                                if (menu_slot_r != 4'd0) menu_slot_r <= menu_slot_r - 4'd1;
                            end
                            else if (button_pressed_event[2] && menu_slot_r != 4'd15)
                                menu_slot_r <= menu_slot_r + 4'd1;
                        end
                    end
                    PAGE_CONFIRM:
                    begin
                        if (!button_pressed_event[3] && button_pressed_event[0])
                        begin
                            command_valid_r <= 1'b1;
                        end
                    end
                    default:
                    begin
                        // 执行中不取消已交付的存储事务，等待一次明确结果。
                    end
                endcase
            end
        end
    end
endmodule
