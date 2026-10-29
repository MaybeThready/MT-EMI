/**
 * spi_nor_flash 模块 v1
 * 单线 SPI NOR 命令层：识别、读取、页编程、4 KiB 扇区擦除和忙轮询。
 * 先以 JEDEC ID + SFDP 校验 128 Mbit、3 字节地址、256 字节页及 20h 擦除。
 * 不修改保护寄存器，不发送整片擦除；地址硬限制为预留的最后 128 KiB。
 * NOTE: 不含 QPI/4-byte 模式恢复；不兼容器件返回错误，不猜测型号后写入。
 */

/** 命令接口（全部使用 clk_sys / rst_sys_n）
 * in_operation：0 读取、1 页编程、2 擦除、3 识别。
 * in_address：24 位字节地址；in_length：1..80 字节，编程不得跨 256 字节页。
 * in_data/out_data：字节 n 在 [8*n +: 8]；无 Q 格式。
 * valid && ready 在同一系统上升沿交付；一次一笔，响应允许背压。
 * out_status：0 成功、2 忙超时、3 不兼容/未识别、5 写使能失败、6 参数非法。
 * jedec_id：厂商/类型/容量字节，便于上板观察；不代表实物已验证。
 * BUSY_TIMEOUT_CYCLES：忙轮询总系统周期上限，默认约 1.02 秒。
 * RELEASE_WAIT_CYCLES：ABh 后等待，默认约 40 us。上电等待由上层完成。
 */
module spi_nor_flash
#(
    parameter HALF_PERIOD_CYCLES = 50,
    parameter BUSY_TIMEOUT_CYCLES = 100000000,
    parameter RELEASE_WAIT_CYCLES = 4096
)(
    input clk_sys,
    input rst_n,
    input in_valid,
    output in_ready,
    input [1:0] in_operation,
    input [23:0] in_address,
    input [6:0] in_length,
    input [639:0] in_data,
    output out_valid,
    input out_ready,
    output [2:0] out_status,
    output [639:0] out_data,
    output [23:0] jedec_id,
    output flash_cs_n,
    output flash_clk,
    output flash_mosi,
    input flash_miso
);
    localparam STATE_IDLE = 5'd0;
    localparam STATE_DISPATCH = 5'd1;
    localparam STATE_WAKE = 5'd2;
    localparam STATE_WAKE_WAIT = 5'd3;
    localparam STATE_DELAY = 5'd4;
    localparam STATE_POLL = 5'd5;
    localparam STATE_POLL_WAIT = 5'd6;
    localparam STATE_ID = 5'd7;
    localparam STATE_ID_WAIT = 5'd8;
    localparam STATE_HEADER = 5'd9;
    localparam STATE_HEADER_WAIT = 5'd10;
    localparam STATE_TABLE = 5'd11;
    localparam STATE_TABLE_WAIT = 5'd12;
    localparam STATE_WREN = 5'd13;
    localparam STATE_WREN_WAIT = 5'd14;
    localparam STATE_WEL = 5'd15;
    localparam STATE_WEL_WAIT = 5'd16;
    localparam STATE_COMMAND = 5'd17;
    localparam STATE_COMMAND_WAIT = 5'd18;
    localparam STATE_RESULT = 5'd19;
    localparam STATE_CAPTURE = 5'd20;
    wire [4:0] current_state;
    reg [4:0] next_state;
    reg [1:0] operation_r;
    reg [23:0] address_r;
    reg [6:0] length_r;
    reg [639:0] data_r;
    reg [639:0] result_r;
    reg valid_r;
    reg [2:0] status_r;
    reg [23:0] jedec_r;
    reg identified_r;
    reg [31:0] timer_r;
    reg [23:0] table_address_r;
    reg [7:0] table_length_r;
    wire timeout;
    wire request_legal;
    wire header_legal;
    wire table_legal;
    wire id_legal;
    wire transfer_ready;
    wire transfer_valid;
    wire [671:0] transfer_data;
    reg packet_valid;
    reg packet_ready;
    reg [6:0] packet_length;
    reg [671:0] packet_data;
    wire [639:0] sfdp_data;

    assign in_ready = rst_n && (current_state == STATE_IDLE);
    assign out_valid = valid_r;
    assign out_status = status_r;
    assign out_data = result_r;
    assign jedec_id = jedec_r;
    assign timeout = (timer_r >= BUSY_TIMEOUT_CYCLES - 1);
    assign sfdp_data = {8'd0, transfer_data[671:40]};
    assign id_legal = (transfer_data[15:8] != 8'h00) && (transfer_data[15:8] != 8'hff)
        && (transfer_data[31:24] == 8'h18);
    // SFDP first parameter header is the mandatory Basic Flash Parameter table.
    assign header_legal = (sfdp_data[31:0] == 32'h50444653)
        && (sfdp_data[47:40] == 8'd1) && (sfdp_data[63:56] == 8'hff)
        && (sfdp_data[71:64] == 8'h00) && (sfdp_data[87:80] == 8'd1)
        && (sfdp_data[95:88] >= 8'd9) && (sfdp_data[127:120] == 8'hff);
    assign table_legal = (sfdp_data[1:0] == 2'b01) && (sfdp_data[15:8] == 8'h20)
        // Only 3-byte-only devices: a previously selected 4-byte address mode must not
        // reinterpret the first payload byte as an address byte during programming.
        && (sfdp_data[18:17] == 2'd0)
        && ((sfdp_data[63:32] == 32'h07ffffff) || (sfdp_data[63:32] == 32'h8000001b))
        && ((table_length_r < 8'd11) || (sfdp_data[327:324] == 4'd8));
    assign request_legal = (HALF_PERIOD_CYCLES >= 4) && (BUSY_TIMEOUT_CYCLES > 0)
        && (RELEASE_WAIT_CYCLES > 0)
        && ((operation_r == 2'd3) || ((address_r[23:17] == 7'h7f)
        && ((operation_r == 2'd2) ? (address_r[11:0] == 12'd0)
        : ((length_r >= 7'd1) && (length_r <= 7'd80)
        && (({1'b0, address_r[7:0]} + {2'd0, length_r}) <= 9'd256)))));

    spi_nor_transfer #(.HALF_PERIOD_CYCLES(HALF_PERIOD_CYCLES)) spi_nor_transfer_u (
        .clk_sys(clk_sys), .rst_n(rst_n), .in_valid(packet_valid), .in_ready(transfer_ready),
        .in_length(packet_length), .in_data(packet_data), .out_valid(transfer_valid),
        .out_ready(packet_ready), .out_data(transfer_data),
        .flash_cs_n(flash_cs_n), .flash_clk(flash_clk), .flash_mosi(flash_mosi), .flash_miso(flash_miso)
    );
    fsm #(.W(5), .INITIAL_STATE(STATE_IDLE)) fsm_u (
        .clk(clk_sys), .rst_n(rst_n), .stn(next_state), .stc(current_state)
    );

    always @(*)
    begin
        packet_valid = 1'b0;
        packet_ready = 1'b0;
        packet_length = 7'd1;
        packet_data = 672'd0;
        next_state = current_state;
        case (current_state)
            STATE_IDLE:
                if (in_valid) next_state = STATE_DISPATCH;
            STATE_DISPATCH:
                if (!request_legal || (!identified_r && (operation_r != 2'd3)))
                    next_state = STATE_RESULT;
                else if (operation_r == 2'd3) next_state = STATE_WAKE;
                else if (operation_r == 2'd0) next_state = STATE_COMMAND;
                else next_state = STATE_WREN;
            STATE_WAKE:
            begin
                packet_valid = 1'b1;
                packet_data[7:0] = 8'hab;
                if (transfer_ready) next_state = STATE_WAKE_WAIT;
            end
            STATE_WAKE_WAIT:
            begin
                packet_ready = 1'b1;
                if (transfer_valid) next_state = STATE_DELAY;
            end
            STATE_DELAY:
                if (timer_r >= RELEASE_WAIT_CYCLES - 1) next_state = STATE_POLL;
            STATE_POLL:
            begin
                packet_valid = 1'b1;
                packet_data[7:0] = 8'h05;
                packet_length = 7'd2;
                if (transfer_ready) next_state = STATE_POLL_WAIT;
            end
            STATE_POLL_WAIT:
            begin
                packet_ready = 1'b1;
                if (transfer_valid)
                begin
                    if (timeout) next_state = STATE_RESULT;
                    else if (transfer_data[8]) next_state = STATE_POLL;
                    else next_state = (operation_r == 2'd3) ? STATE_ID : STATE_RESULT;
                end
            end
            STATE_ID:
            begin
                packet_valid = 1'b1;
                packet_data[7:0] = 8'h9f;
                packet_length = 7'd4;
                if (transfer_ready) next_state = STATE_ID_WAIT;
            end
            STATE_ID_WAIT:
            begin
                packet_ready = 1'b1;
                if (transfer_valid) next_state = id_legal ? STATE_HEADER : STATE_RESULT;
            end
            STATE_HEADER, STATE_TABLE:
            begin
                packet_valid = 1'b1;
                packet_data[7:0] = 8'h5a;
                if (current_state == STATE_TABLE)
                begin
                    packet_data[31:8] = {table_address_r[7:0], table_address_r[15:8], table_address_r[23:16]};
                    packet_length = 7'd49;
                end
                else packet_length = 7'd21;
                if (transfer_ready)
                    next_state = (current_state == STATE_TABLE) ? STATE_TABLE_WAIT : STATE_HEADER_WAIT;
            end
            STATE_HEADER_WAIT:
            begin
                packet_ready = 1'b1;
                if (transfer_valid) next_state = header_legal ? STATE_TABLE : STATE_RESULT;
            end
            STATE_TABLE_WAIT:
            begin
                packet_ready = 1'b1;
                if (transfer_valid) next_state = STATE_RESULT;
            end
            STATE_WREN:
            begin
                packet_valid = 1'b1;
                packet_data[7:0] = 8'h06;
                if (transfer_ready) next_state = STATE_WREN_WAIT;
            end
            STATE_WREN_WAIT:
            begin
                packet_ready = 1'b1;
                if (transfer_valid) next_state = STATE_WEL;
            end
            STATE_WEL:
            begin
                packet_valid = 1'b1;
                packet_data[7:0] = 8'h05;
                packet_length = 7'd2;
                if (transfer_ready) next_state = STATE_WEL_WAIT;
            end
            STATE_WEL_WAIT:
            begin
                packet_ready = 1'b1;
                if (transfer_valid)
                    next_state = (transfer_data[9:8] == 2'b10) ? STATE_COMMAND : STATE_RESULT;
            end
            STATE_COMMAND:
            begin
                packet_valid = 1'b1;
                packet_data[31:8] = {address_r[7:0], address_r[15:8], address_r[23:16]};
                packet_length = 7'd4;
                case (operation_r)
                    2'd0:
                    begin
                        packet_data[7:0] = 8'h03;
                        packet_length = length_r + 7'd4;
                    end
                    2'd1:
                    begin
                        packet_data[7:0] = 8'h02;
                        packet_data[671:32] = data_r;
                        packet_length = length_r + 7'd4;
                    end
                    default: packet_data[7:0] = 8'h20;
                endcase
                if (transfer_ready) next_state = STATE_COMMAND_WAIT;
            end
            STATE_COMMAND_WAIT:
            begin
                packet_ready = 1'b1;
                if (transfer_valid) next_state = (operation_r == 2'd0) ? STATE_CAPTURE : STATE_POLL;
            end
            STATE_CAPTURE: next_state = STATE_RESULT;
            STATE_RESULT:
                if (out_ready) next_state = STATE_IDLE;
            default: next_state = STATE_IDLE;
        endcase
    end

    // 与结果状态同拍有效，复位异步撤销；下游控制不再组合依赖 rst_n。
    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n) valid_r <= 1'b0;
        else valid_r <= (next_state == STATE_RESULT);
    end

    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            operation_r <= 2'd0;
            address_r <= 24'd0;
            length_r <= 7'd0;
            data_r <= 640'd0;
            result_r <= 640'd0;
            status_r <= 3'd0;
            jedec_r <= 24'd0;
            identified_r <= 1'b0;
            timer_r <= 32'd0;
            table_address_r <= 24'd0;
            table_length_r <= 8'd0;
        end
        else
        begin
            if (in_valid && (current_state == STATE_IDLE))
            begin
                operation_r <= in_operation;
                address_r <= in_address;
                length_r <= in_length;
                data_r <= in_data;
                status_r <= 3'd0;
            end
            // 宽数据装载由独立状态控制，不把响应握手/复位门控串到 640 位使能。
            // transfer_data 在响应接收后保持，下一包尚未发起，允许延后一拍装载。
            if (current_state == STATE_DISPATCH) result_r <= 640'd0;
            if (current_state == STATE_CAPTURE) result_r <= transfer_data[671:32];
            if ((current_state != next_state) && ((next_state == STATE_DELAY) || (current_state == STATE_DELAY)
                || (current_state == STATE_COMMAND_WAIT))) timer_r <= 32'd0;
            else if ((current_state == STATE_DELAY) || (current_state == STATE_POLL) || (current_state == STATE_POLL_WAIT))
            begin
                if (timer_r != 32'hffffffff) timer_r <= timer_r + 32'd1;
            end
            if (current_state == STATE_DISPATCH)
            begin
                if (!request_legal) status_r <= 3'd6;
                else if (!identified_r && (operation_r != 2'd3)) status_r <= 3'd3;
                if (operation_r == 2'd3) identified_r <= 1'b0;
            end
            if (transfer_valid && packet_ready)
            begin
                case (current_state)
                    STATE_POLL_WAIT:
                        if (timeout) status_r <= 3'd2;
                    STATE_ID_WAIT:
                    begin
                        jedec_r <= {transfer_data[15:8], transfer_data[23:16], transfer_data[31:24]};
                        if (!id_legal) status_r <= 3'd3;
                    end
                    STATE_HEADER_WAIT:
                    begin
                        table_address_r <= sfdp_data[119:96];
                        table_length_r <= sfdp_data[95:88];
                        if (!header_legal) status_r <= 3'd3;
                    end
                    STATE_TABLE_WAIT:
                    begin
                        identified_r <= table_legal;
                        if (!table_legal) status_r <= 3'd3;
                    end
                    STATE_WEL_WAIT:
                        if (transfer_data[9:8] != 2'b10) status_r <= 3'd5;
                    default: ;
                endcase
            end
        end
    end
endmodule
