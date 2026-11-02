/**
 * 2026-11-02 S2和弦：config[24]为演奏模式子菜单，[5:4]为候选0/1；[23]仍是保存上下文。
 * [31:25]保留0，子菜单仅page=1合法；页面身份为{page,submenu}，切换立即定位选中框。
 * TILE_COUNT扩至2048以容纳追加字形，16位字符RAM内原11位切片编号仍足够。
 * 第三版文字切片/图形列双缓冲场景，不使用全屏像素缓存。
 * 全部状态使用clk_sys/rst_sys_n；坐标与地址为无符号整数，不涉及Q格式。
 * word_valid && word_ready仅写后台，背压期间发送方保持载荷。
 * kind=0：地址为row*ceil(H_ACTIVE/8)+col，单格8×16；data[12:0]为切片编号（小于2048），
 * data[16:13]为前景色，[31:17]保留为0；文字透明，背景由几何层生成。
 * 内部以16位保存11位编号和4位颜色，保持6个字符SDP块；不兼容旧版ASCII绘图字。
 * 特殊地址4095写页面config：[2:0]页，[3]模式1，[5:4]选项/效果，[9:6]槽号，[10]恢复项，
 * [18:11]活动卡片掩码，[22:19]消息颜色，[23]保存上下文，[24]子菜单，[31:25]为0。
 * kind=1：地址为x，[8:0]为最小y，[17:9]为最大y且包含端点，[21:18]颜色，[22]使能，[31:23]为0。
 * 非法字被接收但不写入，并锁存address_error；写完后保持present_valid，直到安全帧边界握手提交。
 * 等待提交时停止写入；交换后先清空新后台，无隐式前台复制，支持稀疏重建。
 * 四拍扫描流水依次处理地址寄存、SDP读、字形与合成；H_ACTIVE范围1..1024，V_ACTIVE范围1..512。
 * 菜单选中条在安全帧边界分六帧移动，可从当前位置重新定向，不阻塞后续UI任务。
 */
module lcd_scene
#(
    parameter H_ACTIVE = 800,
    parameter V_ACTIVE = 480,
    parameter TILE_COUNT = 2048
)(
    input clk,
    input rst_n,
    input word_valid,
    output word_ready,
    input word_kind,
    input [11:0] word_addr,
    input [31:0] word_data,
    input present_valid,
    output present_ready,
    input frame_boundary,
    output frame_active,
    output address_error,
    input scan_active,
    input [9:0] scan_x,
    input [8:0] scan_y,
    output [3:0] pixel_index
);
    localparam CHAR_COLS = (H_ACTIVE + 7) / 8;
    localparam CHAR_COUNT = CHAR_COLS * ((V_ACTIVE + 15) / 16);
    localparam CLEAR_COUNT = (CHAR_COUNT > H_ACTIVE) ? CHAR_COUNT : H_ACTIVE;
    localparam STATE_CLEAR = 2'd0;
    localparam STATE_WRITE = 2'd1;
    localparam STATE_PRESENT = 2'd2;
    wire [1:0] current_state;
    reg [1:0] next_state;
    reg [12:0] clear_addr_r;
    reg front_bank_r, front_valid_r, address_error_r;
    wire accept, commit, valid_word, clearing;
    wire [11:0] write_addr;
    reg [11:0] char_read_addr_r;
    reg read_active_r;
    reg [9:0] read_x_r;
    reg [8:0] read_y_r;
    wire [15:0] char_data [1:0];
    wire [31:0] graph_data [1:0];
    wire [31:0] selected_char;
    wire [31:0] selected_graph;
    wire [7:0] glyph_row;
    reg bank_s0;
    reg [1:0] visible_r;
    reg [9:0] x_s0, x_s1;
    reg [8:0] y_s0, y_s1;
    reg [31:0] char_s1;
    reg [31:0] graph_s1;
    reg [3:0] composed, pixel_index_r;
    genvar bank_index;
    reg [31:0] config_r [0:1];
    wire [31:0] selected_config=bank_s0 ? config_r[1] : config_r[0];
    wire [31:0] incoming_config=front_bank_r ? config_r[0] : config_r[1];
    reg [31:0] config_s1;
    reg [8:0] selection_y_r,origin_y_r,target_y_r,selection_y_s1;
    reg [2:0] motion_phase_r;
    wire [2:0] current_page=front_bank_r ? config_r[1][2:0] : config_r[0][2:0];
    wire current_submenu=front_bank_r ? config_r[1][24] : config_r[0][24];
    wire [8:0] incoming_target=9'd156+{1'b0,incoming_config[5:4],6'd0};
    wire [8:0] slot_y=9'd124+{1'b0,config_s1[8:6],5'd0};
    reg [3:0] background;
    reg [9:0] card_x;
    reg [8:0] card_y;
    integer card;
    assign clearing = (current_state == STATE_CLEAR);
    assign word_ready = rst_n && (current_state == STATE_WRITE) && !present_valid;
    assign present_ready = rst_n && frame_boundary && !clearing;
    assign accept = word_valid && word_ready;
    assign commit = present_valid && present_ready;
    assign valid_word = word_kind ?
    ((word_addr < H_ACTIVE) && (word_data[31:23] == 9'd0) &&
    (!word_data[22] || ((word_data[8:0] <= word_data[17:9]) && (word_data[17:9] < V_ACTIVE)))) :
    (((word_addr < CHAR_COUNT) && (word_data[31:17] == 15'd0) && (word_data[12:0]<TILE_COUNT)) ||
    ((word_addr==12'd4095) && word_data[31:25]==7'd0 &&
     (!word_data[24] || (word_data[2:0]==3'd1 && !word_data[5]))));
    assign write_addr = clearing ? clear_addr_r[11:0] : word_addr;
    assign selected_char = bank_s0 ? {15'd0,char_data[1][14:11],2'd0,char_data[1][10:0]} :
    {15'd0,char_data[0][14:11],2'd0,char_data[0][10:0]};
    assign selected_graph = bank_s0 ? graph_data[1] : graph_data[0];
    assign frame_active = front_valid_r;
    assign address_error = address_error_r;
    assign pixel_index = pixel_index_r;
    // A row is only 5 bits. Explicit constant shifts/adds avoid the unregistered
    // MULT12X12 inferred from row*CHAR_COLS in the failing implementation.
    function [11:0] character_row_offset;
        input [4:0] row;
        integer coefficient_bit;
        reg [11:0] offset;
        begin
            offset = 12'd0;
            for (coefficient_bit = 0; coefficient_bit < 8; coefficient_bit = coefficient_bit + 1)
            begin
                if (((CHAR_COLS >> coefficient_bit) & 1) != 0)
                offset = offset + ({7'd0, row} << coefficient_bit);
            end
            character_row_offset = offset;
        end
    endfunction
    // Register the complete memory request. Ownership switches at the actual
    // memory edge; do not tag requests early or clear a bank still being read.
    always @(posedge clk or negedge rst_n)
    begin
        if (!rst_n)
        begin
            char_read_addr_r <= 12'd0;
            read_active_r <= 1'b0;
            read_x_r <= 10'd0;
            read_y_r <= 9'd0;
        end
        else
        begin
            char_read_addr_r <= character_row_offset(scan_y[8:4]) + {5'd0, scan_x[9:3]};
            read_active_r <= scan_active;
            read_x_r <= scan_x;
            read_y_r <= scan_y;
        end
    end
    fsm #(.W(2), .INITIAL_STATE(STATE_CLEAR)) fsm_u (
    .clk(clk), .rst_n(rst_n), .stn(next_state), .stc(current_state)
    );
    generate
        for (bank_index = 0; bank_index < 2; bank_index = bank_index + 1)
        begin : scene_banks
            lcd_sdp_ram #(.DATA_WIDTH(16), .DEPTH(CHAR_COUNT), .ADDR_WIDTH(12)) char_ram_u (
            .clk(clk), .rst_n(rst_n),
            .wr_en((front_bank_r != bank_index) && ((clearing && (clear_addr_r < CHAR_COUNT)) ||
            (accept && valid_word && !word_kind && word_addr<CHAR_COUNT))),
            .wr_addr(write_addr), .wr_data(clearing ? 16'd0 : {1'b0,word_data[16:13],word_data[10:0]}),
            .rd_en(read_active_r && front_valid_r && (front_bank_r == bank_index)),
            .rd_addr(char_read_addr_r), .rd_data(char_data[bank_index])
            );
            lcd_sdp_ram #(.DATA_WIDTH(32), .DEPTH(H_ACTIVE), .ADDR_WIDTH(12)) graph_ram_u (
            .clk(clk), .rst_n(rst_n),
            .wr_en((front_bank_r != bank_index) && ((clearing && (clear_addr_r < H_ACTIVE)) ||
            (accept && valid_word && word_kind))),
            .wr_addr(write_addr), .wr_data(clearing ? 32'd0 : word_data),
            .rd_en(read_active_r && front_valid_r && (front_bank_r == bank_index)),
            .rd_addr({2'b00, read_x_r}), .rd_data(graph_data[bank_index])
            );
        end
    endgenerate
    lcd_tile_rom lcd_tile_rom_u (
    .clk(clk), .rst_n(rst_n), .rd_en(1'b1), .tile_id(selected_char[12:0]),
    .glyph_y(y_s0[3:0]), .glyph_row(glyph_row)
    );
    always @(*)
    begin
        next_state = current_state;
        case (current_state)
            STATE_CLEAR:
            if (clear_addr_r == CLEAR_COUNT - 1) next_state = STATE_WRITE;
            STATE_WRITE:
            if (commit) next_state = STATE_CLEAR;
            else if (present_valid) next_state = STATE_PRESENT;
            STATE_PRESENT:
            if (commit) next_state = STATE_CLEAR;
            default: next_state = STATE_CLEAR;
        endcase
    end
    always @(posedge clk or negedge rst_n)
    begin
        if (!rst_n)
        begin
            clear_addr_r <= 13'd0;
            front_bank_r <= 1'b0;
            front_valid_r <= 1'b0;
            address_error_r <= 1'b0;
            config_r[0]<=32'd0;
            config_r[1]<=32'd0;
        end
        else
        begin
            if (clearing)
            begin
                if(clear_addr_r==13'd0) config_r[!front_bank_r]<=32'd0;
                if (clear_addr_r == CLEAR_COUNT - 1) clear_addr_r <= 13'd0;
                else clear_addr_r <= clear_addr_r + 13'd1;
            end
            if (commit)
            begin
                front_bank_r <= !front_bank_r;
                front_valid_r <= 1'b1;
            end
            if (accept && !valid_word) address_error_r <= 1'b1;
            if(accept && valid_word && !word_kind && word_addr==12'd4095)
            config_r[!front_bank_r]<=word_data;
        end
    end
    // Carry each pixel's coordinates, visibility and bank through the pipeline.
    always @(posedge clk or negedge rst_n)
    begin
        if (!rst_n)
        begin
            bank_s0 <= 1'b0;
            visible_r <= 2'b00;
            x_s0 <= 10'd0;
            x_s1 <= 10'd0;
            y_s0 <= 9'd0;
            y_s1 <= 9'd0;
            char_s1 <= 32'd0;
            graph_s1 <= 32'd0;
            pixel_index_r <= 4'd0;
            config_s1<=32'd0;
            selection_y_s1<=9'd156;
        end
        else
        begin
            bank_s0 <= front_bank_r;
            visible_r <= {visible_r[0], read_active_r && front_valid_r};
            x_s0 <= read_x_r;
            x_s1 <= x_s0;
            y_s0 <= read_y_r;
            y_s1 <= y_s0;
            char_s1 <= selected_char;
            config_s1<=selected_config;
            selection_y_s1<=selection_y_r;
            graph_s1 <= selected_graph;
            pixel_index_r <= visible_r[1] ? composed : 4'd0;
        end
    end
    always @(*)
    begin
        composed = background;
        if (graph_s1[22] && (y_s1 >= graph_s1[8:0]) && (y_s1 <= graph_s1[17:9]))
        composed = graph_s1[21:18];
        if (glyph_row[7-x_s1[2:0]]) composed = char_s1[16:13];
    end
    // Only local integer geometry is animated. Metadata and text remain frozen.
    // Change coordinates at the same safe memory-frame boundary as bank swap.
    function [8:0] ease_position;
        input [8:0] first,last;
        input [2:0] phase;
        reg signed [17:0] delta,scaled;
        begin
            delta=$signed({1'b0,last})-$signed({1'b0,first});
            case(phase)
                3'd0:scaled=(delta<<<2)+delta;
                3'd1:scaled=(delta<<<4)+delta;
                3'd2:scaled=delta<<<5;
                3'd3:scaled=(delta<<<5)+(delta<<<4)-delta;
                3'd4:scaled=(delta<<<6)-(delta<<<2)-delta;
                default:scaled=delta<<<6;
            endcase
            ease_position=$signed({1'b0,first})+(scaled>>>6);
        end
    endfunction
    always @(posedge clk or negedge rst_n)
    begin
        if(!rst_n)
        begin
            selection_y_r<=9'd156;
            origin_y_r<=9'd156;
            target_y_r<=9'd156;
            motion_phase_r<=3'd6;
        end
        else if(frame_boundary)
        begin
            if(commit && (incoming_config[2:0]==3'd1 || incoming_config[2:0]==3'd6) &&
            (incoming_config[2:0]!=current_page || incoming_config[24]!=current_submenu || !front_valid_r))
            begin
                selection_y_r<=incoming_target;
                origin_y_r<=incoming_target;
                target_y_r<=incoming_target;
                motion_phase_r<=3'd6;
            end
            else if(commit && (incoming_config[2:0]==3'd1 || incoming_config[2:0]==3'd6) && incoming_target!=target_y_r)
            begin
                origin_y_r<=selection_y_r;
                target_y_r<=incoming_target;
                motion_phase_r<=3'd0;
            end
            else if(motion_phase_r<3'd6)
            begin
                selection_y_r<=ease_position(origin_y_r,target_y_r,motion_phase_r);
                motion_phase_r<=motion_phase_r+3'd1;
            end
        end
    end
    always @(*)
    begin
        background=4'd8;
        card_x=10'd0;
        card_y=9'd0;
        if(y_s1<9'd48 || y_s1>=9'd452) background=4'd9;
        if(y_s1==9'd47 && x_s1>=10'd24 && x_s1<10'd776) background=4'd10;
        case(config_s1[2:0])
            3'd0:
            begin
                if(x_s1>=10'd48 && x_s1<=10'd591 && y_s1>=9'd96 && y_s1<=9'd303 &&
                (x_s1==10'd48 || x_s1==10'd184 || x_s1==10'd320 || x_s1==10'd456 || x_s1==10'd591 ||
                y_s1==9'd96 || y_s1==9'd148 || y_s1==9'd200 || y_s1==9'd252 || y_s1==9'd303)) background=4'd10;
                if(x_s1==10'd608 && y_s1>=9'd64 && y_s1<=9'd320) background=4'd10;
                for(card=0;card<8;card=card+1)
                begin
                    card_x=10'd16+(card%4)*10'd192;
                    card_y=(card<4) ? 9'd336 : 9'd392;
                    if(x_s1>=card_x && x_s1<card_x+10'd186 && y_s1>=card_y && y_s1<card_y+9'd56)
                    begin
                        background=config_s1[11+card] ? 4'd10 : 4'd9;
                        if(config_s1[11+card] && x_s1<card_x+10'd3) background=4'd12;
                    end
                end
            end
            3'd1,3'd6:
            if(x_s1>=10'd24 && x_s1<10'd776 && y_s1>=selection_y_s1 && y_s1<selection_y_s1+9'd60)
            background=(x_s1<10'd28) ? 4'd12 : 4'd10;
            3'd2:
            if(x_s1>=(config_s1[9] ? 10'd408 : 10'd24) && x_s1<(config_s1[9] ? 10'd772 : 10'd388) &&
            y_s1>=slot_y && y_s1<slot_y+9'd32)
            background=(x_s1<(config_s1[9] ? 10'd411 : 10'd27)) ? 4'd12 : 4'd10;
            3'd3,3'd4,3'd5:
            if(x_s1>=10'd160 && x_s1<10'd640 && y_s1>=9'd132 && y_s1<9'd356)
            background=(x_s1<10'd162 || x_s1>=10'd638 || y_s1<9'd134 || y_s1>=9'd354) ? config_s1[22:19] : 4'd9;
            3'd7:
            begin
                if(y_s1>=9'd132 && y_s1<9'd264 && ((x_s1>=10'd24 && x_s1<10'd388) || (x_s1>=10'd408 && x_s1<10'd772))) background=4'd9;
                if(x_s1>=10'd24 && x_s1<10'd776 && y_s1>=9'd360 && y_s1<9'd420)
                background=(x_s1<10'd27) ? (config_s1[10] ? 4'd14 : 4'd12) : (config_s1[10] ? 4'd10 : 4'd9);
            end
            default:
            begin
            end
        endcase
    end
endmodule
