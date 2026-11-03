/**
 * 第四版文字切片/图形列双缓冲，clk_sys域，不使用全屏像素缓存。
 * 继承正式版四拍扫描/安全帧边界交换和16位文字RAM映射；握手背压期间载荷不变。
 * kind=0文字格式不变，4095写config；[25]频谱，[30:26]峰值段数，[31]保留0。
 * kind=1地址为x；[8:0]顶部，[17:9]底部，[21:18]色，[22]使能；
 * [31:23]为频谱峰值帽绝对y（511无峰值），与列数据同bank原子提交。
 * 演奏图范围x40..615/y88..327；图形阈值在扫描合成前寄存。
 * 仅演奏页使用16相位颜色，每8个安全帧边界推进；菜单选择直接定位。
 * pixel_phase与pixel_index同拍输出；坐标/计数无符号整数，RGB为6位无符号通道。
 */
module lcd_scene
#(
    parameter H_ACTIVE = 800,
    parameter V_ACTIVE = 480,
    parameter TILE_COUNT = 1977
)(
    input wire clk,
    input wire rst_n,
    input wire word_valid,
    output wire word_ready,
    input wire word_kind,
    input wire [11:0] word_addr,
    input wire [31:0] word_data,
    input wire present_valid,
    output wire present_ready,
    input wire frame_boundary,
    output wire frame_active,
    output wire address_error,
    input wire scan_active,
    input wire [9:0] scan_x,
    input wire [8:0] scan_y,
    output wire [3:0] pixel_index,
    output wire [3:0] pixel_phase
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
    reg [8:0] selection_y_r,selection_y_s1;
    reg [6:0] animation_count_r;
    reg [3:0] phase_s0,phase_s1,pixel_phase_r;
    reg [8:0] halo_top_s1,halo_bottom_s1,cap_bottom_s1;
    reg [3:0] wave_color_s1;

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
    ((word_addr < H_ACTIVE) && ((word_data[31:23] == 9'd511) || (word_data[31:23] < V_ACTIVE)) &&
    (!word_data[22] || ((word_data[8:0] <= word_data[17:9]) && (word_data[17:9] < V_ACTIVE)))) :
    (((word_addr < CHAR_COUNT) && (word_data[31:17] == 15'd0) && (word_data[12:0]<TILE_COUNT)) ||
    ((word_addr==12'd4095) && !word_data[31] && word_data[30:26]<=5'd16 &&
    (!word_data[24] || (word_data[2:0]==3'd1 && !word_data[5]))));
    assign write_addr = clearing ? clear_addr_r[11:0] : word_addr;
    assign selected_char = bank_s0 ? {15'd0,char_data[1][14:11],2'd0,char_data[1][10:0]} :
    {15'd0,char_data[0][14:11],2'd0,char_data[0][10:0]};
    assign selected_graph = bank_s0 ? graph_data[1] : graph_data[0];
    assign frame_active = front_valid_r;
    assign address_error = address_error_r;
    assign pixel_index = pixel_index_r;
    assign pixel_phase = pixel_phase_r;
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
        begin
            : scene_banks
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
            phase_s0<=4'd0;
            phase_s1<=4'd0;
            pixel_phase_r<=4'd0;
            halo_top_s1<=9'd88;
            halo_bottom_s1<=9'd327;
            cap_bottom_s1<=9'd511;
            wave_color_s1<=4'd12;
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
            phase_s0<=animation_count_r[6:3];
            phase_s1<=phase_s0;
            pixel_phase_r<=(config_s1[2:0]==3'd0) ? phase_s1 : 4'd0;
            halo_top_s1<=(selected_graph[8:0]<9'd90) ? 9'd88 : selected_graph[8:0]-9'd2;
            halo_bottom_s1<=(selected_graph[17:9]>9'd325) ? 9'd327 : selected_graph[17:9]+9'd2;
            cap_bottom_s1<=selected_graph[31:23]+9'd1;
            wave_color_s1<=(x_s0<10'd184) ? 4'd12 : (x_s0<10'd328) ? 4'd1 : (x_s0<10'd472) ? 4'd2 : 4'd3;
            pixel_index_r <= visible_r[1] ? composed : 4'd0;
        end
    end
    always @(*)
    begin
        composed=background;
        if (config_s1[2:0]==3'd0 && graph_s1[22] && x_s1>=10'd40 && x_s1<=10'd615 && y_s1>=9'd88 && y_s1<=9'd327)
        begin
            if (!config_s1[25])
            begin
                if (y_s1>=halo_top_s1 && y_s1<=halo_bottom_s1) composed=4'd4;
                if (y_s1>=graph_s1[8:0] && y_s1<=graph_s1[17:9]) composed=wave_color_s1;
            end
            else if (x_s1[3:0]!=4'd8 && x_s1[3:0]!=4'd7)
            begin
                if (y_s1>=graph_s1[8:0] && y_s1<=graph_s1[17:9] && y_s1[2:0]<3'd6)
                composed=(y_s1<9'd148) ? 4'd3 : (y_s1<9'd208) ? 4'd2 : (y_s1<9'd268) ? 4'd1 : 4'd12;
                if (graph_s1[31:23]!=9'd511 && y_s1>=graph_s1[31:23] && y_s1<=cap_bottom_s1) composed=4'd15;
            end
        end
        if (glyph_row[7-x_s1[2:0]]) composed=char_s1[16:13];
    end
    // 菜单没有持续运动；颜色计数按面板真实安全帧推进，与业务提交频率解耦。
    always @(posedge clk or negedge rst_n)
    begin
        if (!rst_n)
        begin
            selection_y_r<=9'd156;
            animation_count_r<=7'd0;
        end
        else if (frame_boundary)
        begin
            animation_count_r<=animation_count_r+7'd1;
            if (commit) selection_y_r<=incoming_target;
        end
    end
    always @(*)
    begin
        background=4'd8;
        card_x=10'd0;
        card_y=9'd0;
        if(y_s1<9'd48 || y_s1>=9'd452) background=4'd9;
        if (x_s1>=10'd16 && x_s1<10'd20 && y_s1>=9'd16 && y_s1<9'd38) background=4'd12;
        if(y_s1==9'd47 && x_s1>=10'd24 && x_s1<10'd776) background=4'd10;
        case(config_s1[2:0])
            3'd0:
            begin
                if(x_s1>=10'd40 && x_s1<=10'd615 && y_s1>=9'd88 && y_s1<=9'd327 &&
                (x_s1==10'd40 || x_s1==10'd184 || x_s1==10'd328 || x_s1==10'd472 || x_s1==10'd615 ||
                y_s1==9'd88 || y_s1==9'd148 || y_s1==9'd208 || y_s1==9'd268 || y_s1==9'd327)) background=4'd10;
                if(x_s1==10'd632 && y_s1>=9'd64 && y_s1<=9'd340) background=4'd10;

                for (card=0;card<16;card=card+1)
                begin
                    if (x_s1>=10'd656+card*7 && x_s1<10'd661+card*7 && y_s1>=9'd240 && y_s1<9'd248)
                    background=(card<config_s1[30:26]) ? ((card>=14) ? 4'd14 : (card>=11) ? 4'd6 : 4'd12) : 4'd10;
                end
                for(card=0;card<8;card=card+1)
                begin
                    card_x=10'd16+(card%4)*10'd192;
                    card_y=(card<4) ? 9'd352 : 9'd400;
                    if(x_s1>=card_x && x_s1<card_x+10'd186 && y_s1>=card_y && y_s1<card_y+9'd40)
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
