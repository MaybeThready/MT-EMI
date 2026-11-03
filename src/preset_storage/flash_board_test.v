/**
 * Flash 板级测试控制器：上电只读恢复 LED2/3；S2/3 切换，S0 保存后自动读回，S1 只读。
 * 复用 preset_storage_driver 的双副本/识别/超时；测试固定占用槽 15（界面第16槽）。
 * NOTE: 该槽记录为测试向量，不是 UI 音色格式，测试保存会覆盖该槽音色。
 */

/** 接口约定
 * clk_sys/rst_n：系统时钟/同步释放的异步低有效复位。
 * buttons：已经同步消抖的按下电平；只响应新按下，忙期间的按键不排队。
 * request_* / response_*：与存储 Driver 的 valid/ready 接口逐项对应。
 * status：0 忙/识别中，1 校验通过，2 空槽，3 驱动错误，4 数据格式/读回不匹配，5 已修改未保存。
 * driver_status：保留 Driver 原始错误码。identified 由 catalog_valid 表示识别扫描通过。
 * led_on：高表示点亮；bit0 忙时闪烁、空闲时表示识别成功；bit1 成功常亮、空槽慢闪、错误快闪。
 * value_led_on：bit0/1 对应 LED2/3，高有效；复位清零，完整读取校验通过后原子恢复。
 * jedec_id：兼容旧接口保留，识别仍由 Driver 完成，本版不再串行显示 ID。
 * 保存/读取优先于同拍编辑；忙期间不修改灯值。保存锁存快照，读回必须等于快照。
 * DISPLAY_HALF_CYCLES：显示半周期，单位系统周期，默认约0.25s。
 */
module flash_board_test
#(
    parameter DISPLAY_HALF_CYCLES = 24561404
)(
    input clk_sys,
    input rst_n,
    input [3:0] buttons,
    input catalog_valid,
    input [23:0] jedec_id,
    output request_valid,
    input request_ready,
    output request_write,
    output [3:0] request_slot,
    output [511:0] request_data,
    input response_valid,
    output response_ready,
    input [2:0] response_status,
    input [511:0] response_data,
    output [2:0] status,
    output [2:0] driver_status,
    output [1:0] value_led_on,
    output [1:0] led_on
);
    localparam STATE_SEND = 3'd0;
    localparam STATE_WAIT = 3'd1;
    localparam STATE_COMPARE = 3'd2;
    localparam STATE_FINISH = 3'd3;
    localparam STATE_IDLE = 3'd4;
    localparam DISPLAY_WIDTH = (DISPLAY_HALF_CYCLES > 1) ? $clog2(DISPLAY_HALF_CYCLES) : 1;
    wire [2:0] current_state;
    reg [2:0] next_state;
    reg [3:0] previous_buttons_r;
    wire [3:0] pressed;
    reg write_r;
    reg armed_r;
    reg [511:0] received_r;
    reg [5:0] byte_index_r;
    reg mismatch_r;
    reg [2:0] status_r;
    reg [2:0] driver_status_r;
    reg [DISPLAY_WIDTH-1:0] display_count_r;
    reg display_phase_r;
    reg slow_phase_r;
    reg [1:0] value_r;
    reg [1:0] snapshot_r;
    reg [1:0] loaded_r;
    reg verify_save_r;
    wire [7:0] expected_byte;
    wire busy;

    genvar byte_index;

    assign pressed = buttons & ~previous_buttons_r;
    assign request_valid = rst_n && (current_state == STATE_SEND);
    assign request_write = write_r;
    assign request_slot = 4'd15;
    generate
        for (byte_index = 0; byte_index < 64; byte_index = byte_index + 1)
        begin : test_bytes
            localparam [7:0] TEST_BYTE = byte_index ^ 8'ha5;
            assign request_data[byte_index*8 +: 8] = (byte_index == 0) ? 8'hd2
                : ((byte_index == 1) ? {6'd0, snapshot_r} : TEST_BYTE);
        end
    endgenerate
    assign response_ready = rst_n && (current_state == STATE_WAIT);
    assign expected_byte = (byte_index_r == 6'd0) ? 8'hd2
        : ((byte_index_r == 6'd1) ? {6'd0, loaded_r} : ({2'b00, byte_index_r} ^ 8'ha5));
    assign value_led_on = value_r;
    assign status = status_r;
    assign driver_status = driver_status_r;
    assign busy = (current_state != STATE_IDLE);
    assign led_on[0] = busy ? display_phase_r : catalog_valid;
    assign led_on[1] = (status_r == 3'd1) || ((status_r == 3'd2) && slow_phase_r)
        || (((status_r == 3'd3) || (status_r == 3'd4)) && display_phase_r);

    fsm #(.W(3), .INITIAL_STATE(STATE_SEND)) fsm_u (
        .clk(clk_sys), .rst_n(rst_n), .stn(next_state), .stc(current_state)
    );
    always @(*)
    begin
        next_state = current_state;
        case (current_state)
            STATE_SEND: if (request_ready) next_state = STATE_WAIT;
            STATE_WAIT:
                if (response_valid)
                begin
                    if (response_status != 3'd0) next_state = STATE_IDLE;
                    else next_state = write_r ? STATE_SEND : STATE_COMPARE;
                end
            STATE_COMPARE: if (byte_index_r == 6'd63) next_state = STATE_FINISH;
            STATE_FINISH: next_state = STATE_IDLE;
            STATE_IDLE: if (armed_r && (pressed[0] || pressed[1])) next_state = STATE_SEND;
            default: next_state = STATE_SEND;
        endcase
    end
    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            previous_buttons_r <= 4'd0;
            write_r <= 1'b0;
            armed_r <= 1'b0;
            received_r <= 512'd0;
            byte_index_r <= 6'd0;
            mismatch_r <= 1'b0;
            status_r <= 3'd0;
            driver_status_r <= 3'd0;
            display_count_r <= '0;
            display_phase_r <= 1'b0;
            slow_phase_r <= 1'b0;
            value_r <= 2'd0;
            snapshot_r <= 2'd0;
            loaded_r <= 2'd0;
            verify_save_r <= 1'b0;
        end
        else
        begin
            previous_buttons_r <= buttons;
            if (display_count_r == DISPLAY_HALF_CYCLES - 1)
            begin
                display_count_r <= '0;
                display_phase_r <= ~display_phase_r;
                if (display_phase_r)
                begin
                    slow_phase_r <= ~slow_phase_r;
                end
            end
            else display_count_r <= display_count_r + 1'b1;
            if ((current_state == STATE_IDLE) && (buttons == 4'd0)) armed_r <= 1'b1;
            if ((current_state == STATE_IDLE) && armed_r && (pressed[0] || pressed[1]))
            begin
                armed_r <= 1'b0;
                // 同时按下时只读优先；不在空闲状态积累写入请求。
                write_r <= pressed[0] && !pressed[1];
                verify_save_r <= pressed[0] && !pressed[1];
                snapshot_r <= value_r;
                status_r <= 3'd0;
                driver_status_r <= 3'd0;
            end
            if ((current_state == STATE_IDLE) && armed_r && !(pressed[0] || pressed[1]) && (|pressed[3:2]))
            begin
                value_r <= value_r ^ pressed[3:2];
                status_r <= 3'd5;
                armed_r <= 1'b0;
            end
            if ((current_state == STATE_WAIT) && response_valid)
            begin
                driver_status_r <= response_status;
                if (response_status != 3'd0)
                    status_r <= (response_status == 3'd1) ? 3'd2 : 3'd3;
                else if (write_r) write_r <= 1'b0;
                else
                begin
                    received_r <= response_data;
                    loaded_r <= response_data[9:8];
                    byte_index_r <= 6'd0;
                    mismatch_r <= 1'b0;
                end
            end
            if (current_state == STATE_COMPARE)
            begin
                mismatch_r <= mismatch_r || (received_r[7:0] != expected_byte);
                received_r <= {8'd0, received_r[511:8]};
                byte_index_r <= byte_index_r + 6'd1;
            end
            if (current_state == STATE_FINISH)
            begin
                if (mismatch_r || (verify_save_r && (loaded_r != snapshot_r))) status_r <= 3'd4;
                else
                begin
                    value_r <= loaded_r;
                    status_r <= 3'd1;
                end
                verify_save_r <= 1'b0;
            end
        end
    end
endmodule
