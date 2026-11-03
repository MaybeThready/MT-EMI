/**
 * 第四版LCD页面绘制调度器，统一clk_sys/rst_n，独立于音频背压。
 * in_valid&&in_ready冻结528位场景、活动/默认掩码、PCM元数据及实际帧计数。
 * 列缓存同步读一拍，2*j/2*j+1为上下端点；576列映射x40..615/y88..327。
 * 波形保留min/max；频谱每16列归并为36柱，峰值保持10个实际面板帧后2像素/帧回落。
 * 只保留36份8位相对高度及4位保持计数，峰值坐标复用原32位列字高9位。
 * word/present在背压时保持载荷，提交后render_done；重置取消未提交任务。
 * 文字数字缩放和BCD保持正式版分拍实现，无变量除法、乘法器或整屏帧缓存。
 */
module drawers
(
    input wire clk_sys, input wire rst_n,
    input wire in_valid, output wire in_ready,
    input wire [15:0] frame_count,
    input wire [527:0] scene_state,
    input wire [21:0] highlight_mask, input wire [21:0] default_mask,
    input wire scene_wave_valid, input wire scene_spectrum_valid, input wire scene_pcm_valid,
    input wire [15:0] scene_output_peak,
    input wire scene_fft_overflow, input wire scene_spectrum_clipped,
    output wire column_rd_en, output wire [10:0] column_rd_addr, input wire [15:0] column_rd_data,
    output wire word_valid, input wire word_ready, output wire word_kind,
    output wire [11:0] word_addr, output wire [31:0] word_data,
    output wire present_valid, input wire present_ready,
    output wire render_done, output wire protocol_error
);
    localparam IDLE=6'd0, CONFIG=6'd1, OBJECT=6'd2, INFO=6'd3,
    TEXT_READ=6'd4, TEXT_WAIT=6'd5, TEXT_SEND=6'd6, NEXT=6'd7,
    DEC_START=6'd8, DEC_WAIT=6'd9, FORMAT=6'd10, DIGIT=6'd11,
    SUFFIX=6'd12, NUM_READY=6'd13, GLYPH_READ=6'd14, GLYPH_WAIT=6'd15,
    GLYPH_SEND=6'd16, COL_TOP=6'd17, WAIT_TOP=6'd18,
    COL_BOTTOM=6'd19, WAIT_BOTTOM=6'd20, GRAPH_SEND=6'd21,
    PRESENT=6'd22, DONE=6'd23, INFO_DECIDE=6'd24, OBJECT_DECIDE=6'd25,
    SCALE_A=6'd26, SCALE_B=6'd27, SCALE_C=6'd28, SCALE_D=6'd29,
    STARTUP=6'd30, CONFIG_PREP=6'd31, GROUP_READ=6'd32, GROUP_DECIDE=6'd33, GROUP_WRITE=6'd34;
    // Registered one-hot controls: no page/ROM result may pass through the
    // next-state decoder into a same-cycle word-valid/CE output wire.
    reg [34:0] state /* synthesis syn_preserve = 1 */;
    reg [34:0] next_state;
    reg [527:0] snapshot_r;
    reg [21:0] activity_r,defaults_r;
    reg wave_r,spectrum_r,pcm_r,overflow_r,clipped_r,error_r;
    reg [15:0] peak_r;
    reg [5:0] object_index_r;
    wire object_valid,object_number;
    wire [6:0] object_col;
    wire [4:0] object_row;
    wire [3:0] object_color,object_suffix;
    wire [7:0] object_string;
    wire [23:0] object_value;
    wire [2:0] object_scale;
    wire [1:0] object_style,object_sign;
    wire [2:0] object_decimals,object_minimum;
    wire object_negative;
    wire [31:0] scene_config;
    reg [6:0] col_r;
    reg [4:0] row_r;
    reg [3:0] color_r,suffix_r;
    reg [7:0] string_r,text_index_r,text_count_r;
    reg [11:0] text_start_r;
    reg [23:0] number_r;
    reg [2:0] scale_r;
    reg object_valid_r,object_number_r;
    reg [31:0] scale_a_r,scale_b_r,scale_c_r,scale_ab_r,scale_total_r;
    wire [31:0] scale_raw={16'd0,number_r[15:0]};
    reg [1:0] style_r,sign_r;
    reg [2:0] decimals_r,minimum_r;
    reg negative_r;
    wire [11:0] string_start;
    wire [7:0] string_count;
    wire [31:0] text_entry;
    wire decimal_ready,decimal_valid;
    wire [31:0] decimal_bcd;
    reg [31:0] bcd_r;
    reg [127:0] ascii_r;
    reg [4:0] ascii_count_r,char_index_r;
    reg [3:0] digit_left_r,suffix_index_r,tile_index_r;
    reg dot_r;
    reg [3:0] required_digits;
    reg [4:0] character_id;
    wire [6:0] character=ascii_r[8*char_index_r +:8];
    wire [12:0] glyph_tile;
    reg [2:0] tile_dx,tile_dy;
    wire [3:0] last_tile=(style_r==2'd0) ? 4'd0 : (style_r==2'd2) ? 4'd8 : 4'd3;
    wire [6:0] character_x=(style_r==2'd0) ? char_index_r :
    (style_r==2'd2) ? ((char_index_r<<1)+char_index_r) : (char_index_r<<1);
    reg [11:0] address_r;
    reg [31:0] data_r;
    reg [9:0] column_r;
    reg [8:0] column_top_r;
    reg [8:0] group_top_r;
    reg [3:0] emit_r;
    reg [7:0] peak_height [0:35];
    reg [3:0] peak_hold [0:35];
    reg [7:0] old_height_r,new_height_r,result_height_r;
    reg [3:0] old_hold_r,result_hold_r;
    reg [15:0] previous_frame_r;
    reg [7:0] elapsed_r;
    reg history_r,history_job_r;
    wire [15:0] elapsed_frames=frame_count-previous_frame_r;
    wire [8:0] decay_pixels=({1'b0,elapsed_r}-{5'd0,old_hold_r})<<1;
    integer i;
    assign in_ready=state[IDLE];
    assign render_done=state[DONE];
    assign protocol_error=error_r;
    assign word_valid=(state[CONFIG] || state[TEXT_SEND] || state[GLYPH_SEND] || state[GRAPH_SEND]);
    assign word_kind=state[GRAPH_SEND];
    assign word_addr=address_r;
    assign word_data=data_r;
    assign present_valid=state[PRESENT];
    assign column_rd_en=(state[COL_TOP] || state[COL_BOTTOM]);
    assign column_rd_addr={column_r,(state[COL_BOTTOM])};
    lcd_page_program lcd_page_program_u (
    .s(snapshot_r),.activity(activity_r),.defaults(defaults_r),
    .pcm_valid(pcm_r),.graph_valid(wave_r || spectrum_r),.fft_overflow(overflow_r),
    .spectrum_clipped(clipped_r),.output_peak(peak_r),.object_index(object_index_r),
    .object_valid(object_valid),.object_col(object_col),.object_row(object_row),
    .object_color(object_color),.string_id(object_string),.number_enable(object_number),
    .number_value(object_value),.font_style(object_style),.decimal_places(object_decimals),
    .number_scale(object_scale),
    .suffix(object_suffix),.negative(object_negative),.sign_mode(object_sign),
    .minimum_digits(object_minimum),.scene_config(scene_config)
    );
    lcd_text_info lcd_text_info_u(.string_id(string_r),.start_addr(string_start),.entry_count(string_count));
    lcd_text_rom lcd_text_rom_u(.clk(clk_sys),.rst_n(rst_n),.rd_en(state[TEXT_READ]),
    .entry_addr(text_start_r+text_index_r),.entry_data(text_entry));
    lcd_decimal lcd_decimal_u(.clk(clk_sys),.rst_n(rst_n),.in_valid(state[DEC_START]),
    .in_ready(decimal_ready),.binary_value(number_r),.out_valid(decimal_valid),
    .out_ready(state[DEC_WAIT]),.bcd(decimal_bcd));
    lcd_glyph_rom lcd_glyph_rom_u(.clk(clk_sys),.rst_n(rst_n),.rd_en(state[GLYPH_READ]),
    .font_style(style_r),.character_id(character_id),.tile_index(tile_index_r),.tile_id(glyph_tile));
    function [11:0] cell_address;
        input [5:0] row;
        input [7:0] col;
        reg [11:0] r;
        begin
            r={6'd0,row};
            cell_address=(r<<6)+(r<<5)+(r<<2)+col;
        end
    endfunction
    function [7:0] suffix_char;
        input [3:0] kind;
        input [3:0] index;
        reg [31:0] chars;
        begin
            case(kind)
                4'd1:chars=35'h00002520;
                4'd2:chars=35'h00736d20;
                4'd3:chars=35'h00007820;
                4'd4:chars=35'h67656420;
                4'd5:chars=35'h007a4820;
                4'd6:chars=35'h706d7320;
                4'd7:chars=35'h00534620;
                4'd8:chars=35'h00746320;
                4'd9:chars=35'h32332f20;
                default:chars=32'd0;
            endcase
            suffix_char=(index<4) ? chars[8*index +:8] : 8'd0;
        end
    endfunction
    always @(*)
    begin
        required_digits=4'd1;
        for(i=0;i<8;i=i+1)
        begin
            if(bcd_r[4*i +:4]!=4'd0) required_digits=i+1;
        end
        if(required_digits<minimum_r) required_digits={1'b0,minimum_r};
        if(required_digits<=decimals_r) required_digits={1'b0,decimals_r}+4'd1;
        tile_dx=3'd0;
        tile_dy=3'd0;
        if (style_r!=2'd0 && style_r!=2'd2)
        begin
            tile_dx={2'd0,tile_index_r[0]};
            tile_dy={2'd0,tile_index_r[1]};
        end
        if (style_r==2'd2)
        begin
            tile_dx=(tile_index_r<4'd3) ? tile_index_r : (tile_index_r<4'd6) ? tile_index_r-4'd3 : tile_index_r-4'd6;
            tile_dy=(tile_index_r<4'd3) ? 3'd0 : (tile_index_r<4'd6) ? 3'd1 : 3'd2;
        end
        case(character)
            // Generated by finish_drawers.py from the bundled alphabet.
            7'd48: character_id=5'd0;
            7'd49: character_id=5'd1;
            7'd50: character_id=5'd2;
            7'd51: character_id=5'd3;
            7'd52: character_id=5'd4;
            7'd53: character_id=5'd5;
            7'd54: character_id=5'd6;
            7'd55: character_id=5'd7;
            7'd56: character_id=5'd8;
            7'd57: character_id=5'd9;
            7'd32: character_id=5'd10;
            7'd46: character_id=5'd11;
            7'd45: character_id=5'd12;
            7'd43: character_id=5'd13;
            7'd37: character_id=5'd14;
            7'd120: character_id=5'd15;
            7'd109: character_id=5'd16;
            7'd115: character_id=5'd17;
            7'd100: character_id=5'd18;
            7'd101: character_id=5'd19;
            7'd103: character_id=5'd20;
            7'd72: character_id=5'd21;
            7'd122: character_id=5'd22;
            7'd99: character_id=5'd23;
            7'd116: character_id=5'd24;
            7'd112: character_id=5'd25;
            7'd47: character_id=5'd26;
            7'd70: character_id=5'd27;
            7'd83: character_id=5'd28;
            7'd63: character_id=5'd29;
            default:character_id=5'd0;
        endcase
    end
    always @(*)
    begin
        next_state=state;
        case(1'b1)
            state[STARTUP]:next_state=35'h00000001;
            state[IDLE]:if(in_valid) next_state=35'h80000000;
            state[CONFIG_PREP]:next_state=35'h00000002;
            state[CONFIG]:if(word_ready) next_state=35'h00000004;
            state[OBJECT]:next_state=35'h02000000;
            state[OBJECT_DECIDE]:next_state=object_valid_r ? (object_number_r ? ((scale_r==3'd0) ? 35'h00000100 : 35'h04000000) : 35'h00000008) :
            ((snapshot_r[422:420]==3'd0 && (wave_r || spectrum_r)) ? 35'h00020000 : 35'h00400000);
            state[INFO]:next_state=35'h01000000;
            state[INFO_DECIDE]:next_state=(text_count_r==8'd0) ? 35'h00000080 : 35'h00000010;
            state[SCALE_A]:next_state=35'h08000000;
            state[SCALE_B]:next_state=35'h10000000;
            state[SCALE_C]:next_state=35'h20000000;
            state[SCALE_D]:next_state=35'h00000100;
            state[TEXT_READ]:next_state=35'h00000020;
            state[TEXT_WAIT]:next_state=35'h00000040;
            state[TEXT_SEND]:if(word_ready) next_state=(text_index_r+8'd1==text_count_r) ? 35'h00000080 : 35'h00000010;
            state[NEXT]:next_state=35'h00000004;
            state[DEC_START]:if(decimal_ready) next_state=35'h00000200;
            state[DEC_WAIT]:if(decimal_valid) next_state=35'h00000400;
            state[FORMAT]:next_state=35'h00000800;
            state[DIGIT]:if(!(decimals_r!=0 && digit_left_r==decimals_r && !dot_r) && digit_left_r==1) next_state=35'h00001000;
            state[SUFFIX]:if(suffix_char(suffix_r,suffix_index_r)==8'd0) next_state=35'h00002000;
            state[NUM_READY]:next_state=35'h00004000;
            state[GLYPH_READ]:next_state=35'h00008000;
            state[GLYPH_WAIT]:next_state=35'h00010000;
            state[GLYPH_SEND]:if(word_ready) next_state=(tile_index_r==last_tile && char_index_r+1==ascii_count_r) ? 35'h00000080 : 35'h00004000;
            state[COL_TOP]:next_state=35'h00040000;
            state[WAIT_TOP]:next_state=35'h00080000;
            state[COL_BOTTOM]:next_state=35'h00100000;
            state[WAIT_BOTTOM]:next_state=(spectrum_r && column_r[3:0]!=4'd15) ? 35'h00020000 : spectrum_r ? 35'h100000000 : 35'h00200000;
            state[GROUP_READ]:next_state=35'h200000000;
            state[GROUP_DECIDE]:next_state=35'h400000000;
            state[GROUP_WRITE]:next_state=35'h00200000;
            state[GRAPH_SEND]:if(word_ready) next_state=(spectrum_r && emit_r!=4'd15) ? 35'h00200000 : (column_r==10'd575) ? 35'h00400000 : 35'h00020000;
            state[PRESENT]:if(present_ready) next_state=35'h00800000;
            state[DONE]:next_state=35'h00000001;
            default:next_state=35'h00000001;
        endcase
    end
    always @(posedge clk_sys or negedge rst_n)
    begin
        if(!rst_n) state<=35'h40000000;
        else state<=next_state;
    end
    always @(posedge clk_sys or negedge rst_n)
    begin
        if(!rst_n)
        begin
            snapshot_r<=528'd0;
            activity_r<=22'd0;
            defaults_r<=22'd0;
            wave_r<=1'b0;
            spectrum_r<=1'b0;
            pcm_r<=1'b0;
            overflow_r<=1'b0;
            clipped_r<=1'b0;
            error_r<=1'b0;
            peak_r<=16'd0;
            object_index_r<=6'd0;
            col_r<=7'd0;
            row_r<=5'd0;
            color_r<=4'd0;
            suffix_r<=4'd0;
            string_r<=8'd0;
            text_index_r<=8'd0;
            text_count_r<=8'd0;
            text_start_r<=12'd0;
            number_r<=24'd0;
            scale_r<=3'd0;
            object_valid_r<=1'b0;
            object_number_r<=1'b0;
            scale_a_r<=32'd0;
            scale_b_r<=32'd0;
            scale_c_r<=32'd0;
            scale_ab_r<=32'd0;
            scale_total_r<=32'd0;
            style_r<=2'd0;
            sign_r<=2'd0;
            decimals_r<=3'd0;
            minimum_r<=3'd1;
            negative_r<=1'b0;
            bcd_r<=32'd0;
            ascii_r<=128'd0;
            ascii_count_r<=5'd0;
            char_index_r<=5'd0;
            digit_left_r<=4'd0;
            suffix_index_r<=4'd0;
            tile_index_r<=4'd0;
            dot_r<=1'b0;
            address_r<=12'd0;
            data_r<=32'd0;
            column_r<=10'd0;
            column_top_r<=9'd0;
            group_top_r<=9'd327;
            emit_r<=4'd0;
            old_height_r<=8'd0;
            new_height_r<=8'd0;
            result_height_r<=8'd0;
            old_hold_r<=4'd0;
            result_hold_r<=4'd0;
            previous_frame_r<=16'd0;
            elapsed_r<=8'd0;
            history_r<=1'b0;
            history_job_r<=1'b0;
            for (i=0;i<36;i=i+1)
            begin
                peak_height[i]<=8'd0;
                peak_hold[i]<=4'd0;
            end
        end
        else
        begin
            if(state[IDLE] && in_valid)
            begin
                snapshot_r<=scene_state;
                activity_r<=highlight_mask;
                defaults_r<=default_mask;
                wave_r<=scene_wave_valid;
                spectrum_r<=scene_spectrum_valid;
                pcm_r<=scene_pcm_valid;
                peak_r<=scene_output_peak;
                overflow_r<=scene_fft_overflow;
                clipped_r<=scene_spectrum_clipped;
                object_index_r<=6'd0;
                column_r<=10'd0;
                group_top_r<=9'd327;
                history_job_r<=history_r;
                history_r<=(scene_state[422:420]==3'd0 && scene_spectrum_valid);
                if (scene_state[422:420]==3'd0 && scene_spectrum_valid)
                begin
                    previous_frame_r<=frame_count;
                    elapsed_r<=(elapsed_frames>16'd255) ? 8'd255 : elapsed_frames[7:0];
                end
                if((scene_wave_valid && scene_spectrum_valid) ||
                (scene_wave_valid && scene_state[500]) ||
                (scene_spectrum_valid && !scene_state[500]) ||
                (scene_state[510] && scene_state[422:420]!=3'd1)) error_r<=1'b1;
            end
            if(state[CONFIG_PREP])
            begin
                address_r<=12'd4095;
                data_r<=scene_config;
            end
            if(state[OBJECT])
            begin
                col_r<=object_col;
                row_r<=object_row;
                color_r<=object_color;
                string_r<=object_string;
                number_r<=object_value;
                scale_r<=object_scale;
                object_valid_r<=object_valid;
                object_number_r<=object_number;
                style_r<=object_style;
                sign_r<=object_sign;
                decimals_r<=object_decimals;
                minimum_r<=object_minimum;
                suffix_r<=object_suffix;
                negative_r<=object_negative;
            end
            // Shared constant arithmetic. Select the raw field first, then
            // register each adder level; rounding is included in the third
            // partial operand. No multiplier/DSP or relaxed clock is used.
            if(state[SCALE_A])
            begin
                case(scale_r)
                    3'd1:
                    begin
                        scale_a_r<=(scale_raw<<6)+(scale_raw<<5);
                        scale_b_r<=(scale_raw<<2)+32'd16384;
                        scale_c_r<=32'd0;
                    end
                    3'd5:
                    begin
                        scale_a_r<=(scale_raw<<7)+(scale_raw<<6);
                        scale_b_r<=(scale_raw<<3)+32'd16384;
                        scale_c_r<=32'd0;
                    end
                    default:
                    begin
                        scale_a_r<=(scale_raw<<13)+(scale_raw<<10);
                        scale_b_r<=(scale_raw<<9)+(scale_raw<<8);
                        case(scale_r)
                            3'd2:scale_c_r<=(scale_raw<<4)+32'd32768;
                            3'd3:scale_c_r<=(scale_raw<<4)+32'd2048;
                            default:scale_c_r<=(scale_raw<<4)+32'd8192;
                        endcase
                    end
                endcase
            end
            if(state[SCALE_B]) scale_ab_r<=scale_a_r+scale_b_r;
            if(state[SCALE_C]) scale_total_r<=scale_ab_r+scale_c_r;
            if(state[SCALE_D])
            begin
                case(scale_r)
                    3'd1,3'd5:number_r<={7'd0,scale_total_r[31:15]};
                    3'd2:number_r<={8'd0,scale_total_r[31:16]};
                    3'd3:number_r<={4'd0,scale_total_r[31:12]};
                    default:number_r<={6'd0,scale_total_r[31:14]};
                endcase
            end
            if(state[INFO])
            begin
                text_start_r<=string_start;
                text_count_r<=string_count;
                text_index_r<=8'd0;
            end
            if(state[TEXT_WAIT])
            begin
                address_r<=cell_address({1'b0,row_r}+text_entry[21:19],{1'b0,col_r}+text_entry[18:13]);
                data_r<={15'd0,color_r,text_entry[12:0]};
            end
            if(state[TEXT_SEND] && word_ready) text_index_r<=text_index_r+8'd1;
            if(state[NEXT]) object_index_r<=object_index_r+6'd1;
            if(state[DEC_WAIT] && decimal_valid) bcd_r<=decimal_bcd;
            if(state[FORMAT])
            begin
                ascii_r<=128'd0;
                digit_left_r<=required_digits;
                dot_r<=1'b0;
                suffix_index_r<=4'd0;
                if((negative_r && sign_r!=2'd0) || sign_r==2'd2)
                begin
                    ascii_r[7:0]<=negative_r ? 8'h2d : 8'h2b;
                    ascii_count_r<=5'd1;
                end
                else ascii_count_r<=5'd0;
            end
            if(state[DIGIT])
            begin
                ascii_count_r<=ascii_count_r+5'd1;
                if(decimals_r!=0 && digit_left_r==decimals_r && !dot_r)
                begin
                    ascii_r[8*ascii_count_r +:8]<=8'h2e;
                    dot_r<=1'b1;
                end
                else
                begin
                    ascii_r[8*ascii_count_r +:8]<=8'h30+{4'd0,bcd_r[4*(digit_left_r-1) +:4]};
                    digit_left_r<=digit_left_r-4'd1;
                end
            end
            if(state[SUFFIX] && suffix_char(suffix_r,suffix_index_r)!=8'd0)
            begin
                ascii_r[8*ascii_count_r +:8]<=suffix_char(suffix_r,suffix_index_r);
                ascii_count_r<=ascii_count_r+5'd1;
                suffix_index_r<=suffix_index_r+4'd1;
            end
            if(state[NUM_READY])
            begin
                char_index_r<=5'd0;
                tile_index_r<=4'd0;
            end
            if(state[GLYPH_WAIT])
            begin
                address_r<=cell_address({1'b0,row_r}+tile_dy,{1'b0,col_r}+character_x+tile_dx);
                data_r<={15'd0,color_r,glyph_tile};
            end
            if(state[GLYPH_SEND] && word_ready)
            begin
                if(tile_index_r==last_tile)
                begin
                    tile_index_r<=4'd0;
                    char_index_r<=char_index_r+5'd1;
                end
                else tile_index_r<=tile_index_r+4'd1;
            end
            if(state[WAIT_TOP]) column_top_r<=column_rd_data[8:0];
            if (state[WAIT_BOTTOM])
            begin
                address_r<=12'd40+column_r;
                data_r<={9'd511,1'b1,4'd12,column_rd_data[8:0],column_top_r};
                if (column_top_r>column_rd_data[8:0] || column_rd_data[8:0]>9'd327 || column_top_r<9'd88) error_r<=1'b1;
                if (spectrum_r)
                begin
                    if (column_top_r<group_top_r) group_top_r<=column_top_r;
                    if (column_r[3:0]!=4'd15) column_r<=column_r+10'd1;
                end
            end
            // 串行先读取峰值状态，再比较，再写入；不串接36选1与更新加法。
            if (state[GROUP_READ])
            begin
                old_height_r<=peak_height[column_r[9:4]];
                old_hold_r<=peak_hold[column_r[9:4]];
                new_height_r<=9'd327-group_top_r;
            end
            if (state[GROUP_DECIDE])
            begin
                if (!history_job_r || new_height_r>=old_height_r)
                begin
                    result_height_r<=new_height_r;
                    result_hold_r<=4'd10;
                end
                else if (elapsed_r<={4'd0,old_hold_r})
                begin
                    result_height_r<=old_height_r;
                    result_hold_r<=old_hold_r-elapsed_r;
                end
                else
                begin
                    result_height_r<=(decay_pixels>=old_height_r || old_height_r-decay_pixels<new_height_r) ? new_height_r : old_height_r-decay_pixels;
                    result_hold_r<=4'd0;
                end
            end
            if (state[GROUP_WRITE])
            begin
                peak_height[column_r[9:4]]<=result_height_r;
                peak_hold[column_r[9:4]]<=result_hold_r;
                address_r<=12'd40+{column_r[9:4],4'd0};
                data_r<={(9'd327-{1'b0,result_height_r}),1'b1,4'd12,9'd327,group_top_r};
                emit_r<=4'd0;
            end
            if (state[GRAPH_SEND] && word_ready)
            begin
                if (spectrum_r && emit_r!=4'd15)
                begin
                    address_r<=address_r+12'd1;
                    emit_r<=emit_r+4'd1;
                end
                else
                begin
                    column_r<=column_r+10'd1;
                    group_top_r<=9'd327;
                end
            end
        end
    end
endmodule
