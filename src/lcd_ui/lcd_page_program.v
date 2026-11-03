/**
 * 第四版冻结页面对象译码，clk_sys域组合逻辑；坐标为8×16文字格。
 * 保留正式和弦快照[509:511]和分拍数值缩放接口。
 * config[25]频谱视图，[30:26]峰值表段数0..16，[31]保留0；其余字段沿用。
 */
module lcd_page_program
(
    input [544:0] s,
    input [21:0] activity,
    input [21:0] defaults,
    input pcm_valid, input graph_valid, input fft_overflow, input spectrum_clipped,
    input [15:0] output_peak,
    input [5:0] object_index,
    output object_valid,
    output [6:0] object_col,
    output [4:0] object_row,
    output [3:0] object_color,
    output [7:0] string_id,
    output number_enable,
    output [23:0] number_value,
    output [2:0] number_scale,
    output [1:0] font_style,
    output [2:0] decimal_places,
    output [3:0] suffix,
    output negative,
    output [1:0] sign_mode,
    output [2:0] minimum_digits,
    output [31:0] scene_config
) /* synthesis syn_romstyle = "logic" */;
    reg object_valid_r;
    assign object_valid=object_valid_r;
    reg [6:0] object_col_r;
    assign object_col=object_col_r;
    reg [4:0] object_row_r;
    assign object_row=object_row_r;
    reg [3:0] object_color_r;
    assign object_color=object_color_r;
    reg [7:0] string_id_r;
    assign string_id=string_id_r;
    reg number_enable_r;
    assign number_enable=number_enable_r;
    reg [23:0] number_value_r;
    assign number_value=number_value_r;
    reg [2:0] number_scale_r;
    assign number_scale=number_scale_r;
    reg [1:0] font_style_r;
    assign font_style=font_style_r;
    reg [2:0] decimal_places_r;
    assign decimal_places=decimal_places_r;
    reg [3:0] suffix_r;
    assign suffix=suffix_r;
    reg negative_r;
    assign negative=negative_r;
    reg [1:0] sign_mode_r;
    assign sign_mode=sign_mode_r;
    reg [2:0] minimum_digits_r;
    assign minimum_digits=minimum_digits_r;
    wire [2:0] page=s[422:420];
    wire play_submenu=(page==3'd1) && s[510];
    wire mode1=(s[417:416]==2'd1);
    wire fine=s[418], view=s[500], save=s[429];
    wire [3:0] slot=s[428:425];
    wire [1:0] effect=s[435:434];
    wire result_ok=(s[433:430]==4'd0);
    wire [2:0] error_index=(s[433:430]<4'd7) ? s[432:430] : 3'd7;
    wire [15:0] wave_number=mode1 ? s[63:48] : s[47:32];
    reg [7:0] active_cards;
    reg [21:0] visible_mask;
    wire [21:0] reset_visible=defaults & visible_mask;
    wire step_active=activity[mode1 ? 1 : 0];
    wire [23:0] progress_abs={8'd0,(s[399] ? (~s[399:384]+16'd1) : s[399:384])};
    wire bend_negative=(s[527:512]<16'h8000);
    wire [15:0] bend_delta=bend_negative ? (16'd32768-s[527:512]) : (s[527:512]-16'd32768);
    wire [3:0] message_color=(page==3'd5) ? (result_ok ? 4'd13 : 4'd14) :
    (save && (page==3'd3) && (!s[437] || s[438+slot])) ? 4'd14 : 4'd12;
    wire [23:0] effect_mix={8'd0,base(8+effect)};
    reg [23:0] advanced_value_0,advanced_value_1;
    reg [2:0] advanced_decimal_0,advanced_decimal_1;
    reg [2:0] advanced_scale_0,advanced_scale_1;
    reg [3:0] advanced_suffix_0,advanced_suffix_1;
    reg min_hit;
    integer k,parameter_index;
    wire [4:0] peak_segments=!pcm_valid ? 5'd0 : output_peak[15] ? 5'd16 : {1'b0,output_peak[14:11]};
    assign scene_config={1'b0,peak_segments,view,play_submenu,save,message_color,active_cards,s[436],slot,
    (play_submenu ? {1'b0,s[511]} : ((page==3'd6) ? effect : s[424:423])),mode1,page};
    function [15:0] base;
        input integer index;
        begin
            base=s[32+16*index +: 16];
        end
    endfunction
    function [15:0] parameter_value;
        input integer index;
        begin
            case(index)
                0:parameter_value=base(0);
                1:parameter_value=base(1);
                2:parameter_value=base(2);
                3:parameter_value=base(3);
                4:parameter_value=s[239:224];
                5:parameter_value=s[255:240];
                6:parameter_value=base(4);
                7:parameter_value=base(5);
                8:parameter_value=base(6);
                9:parameter_value=base(7);
                default:parameter_value=base(index-2);
            endcase
        end
    endfunction
    always @(*)
    begin
        visible_mask=22'd0;
        active_cards=8'd0;
        min_hit=1'b0;
        parameter_index=0;
        for(k=0;k<8;k=k+1)
        begin
            case(k)
                0:parameter_index=mode1 ? 1 : 0;
                1:parameter_index=mode1 ? 3 : 2;
                2:parameter_index=4;
                3:parameter_index=5;
                default:parameter_index=mode1 ? k+6 : k+2;
            endcase
            visible_mask[parameter_index]=1'b1;
            active_cards[k]=activity[parameter_index];
            if(activity[parameter_index])
            begin
                if(((parameter_index==6 || parameter_index==7) && parameter_value(parameter_index)==16'd1) ||
                ((parameter_index!=6 && parameter_index!=7) && parameter_value(parameter_index)==16'd0 &&
                (k!=0 || s[399:384]==16'd0))) min_hit=1'b1;
            end
        end
        advanced_decimal_0=3'd4;
        advanced_decimal_1=3'd4;
        advanced_scale_0=3'd2;
        advanced_scale_1=3'd2;
        advanced_suffix_0=4'd0;
        advanced_suffix_1=4'd0;
        advanced_value_0={8'd0,s[256+32*effect +:16]};
        advanced_value_1={8'd0,s[272+32*effect +:16]};
        case(effect)
            2'd1:
            begin
                advanced_value_0={8'd0,s[303:288]};
                advanced_scale_0=3'd0;
                advanced_decimal_0=3'd0;
                advanced_suffix_0=4'd6;
            end
            2'd2:
            begin
                advanced_value_0={8'd0,s[335:320]};
                advanced_scale_0=3'd3;
                advanced_suffix_0=4'd3;
            end
            2'd3:
            begin
                advanced_value_0={8'd0,s[367:352]};
                advanced_scale_0=3'd4;
                advanced_suffix_0=4'd5;
                advanced_value_1={8'd0,s[383:368]};
                advanced_scale_1=3'd0;
                advanced_decimal_1=3'd0;
                advanced_suffix_1=4'd6;
            end
            default:
            begin
            end
        endcase
    end
    always @(*)
    begin
        object_valid_r=1'b1;
        object_col_r=7'd0;
        object_row_r=5'd0;
        object_color_r=4'd15;
        string_id_r=8'd0;
        number_enable_r=1'b0;
        number_value_r=24'd0;
        number_scale_r=3'd0;
        font_style_r=2'd1;
        decimal_places_r=3'd0;
        suffix_r=4'd0;
        negative_r=1'b0;
        sign_mode_r=2'd0;
        minimum_digits_r=3'd1;
        case ({play_submenu,page})
            4'd0:
            begin
                case (object_index)
                    6'd0:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd3,5'd0,4'd15};
                        string_id_r = 8'd1;
                    end
                    6'd1:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd19,5'd0,4'd15};
                        string_id_r = 8'd2;
                    end
                    6'd2:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd4,5'd4,4'd15};
                        string_id_r = view ? 8'd3 : 8'd4;
                    end
                    6'd3:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {(fine ? 7'd72 : 7'd69),5'd4,4'd15};
                        string_id_r = fine ? 8'd5 : 8'd6;
                    end
                    6'd4:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd82,5'd4,4'd11};
                        string_id_r = 8'd7;
                    end
                    6'd5:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd82,5'd8,4'd11};
                        string_id_r = 8'd8;
                    end
                    6'd6:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd82,5'd12,4'd11};
                        string_id_r = 8'd9;
                    end
                    6'd7:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd82,5'd5,4'd15};
                        number_enable_r = 1'b1;
                        number_value_r = {18'd0, s[506:501]};
                        number_scale_r = 3'd0;
                        font_style_r = 2'd3;
                        decimal_places_r = 3'd0;
                        suffix_r = 4'd9;
                        negative_r = 1'b0;
                        sign_mode_r = 2'd0;
                        minimum_digits_r = 3'd2;
                        if (!s[507])
                        begin
                            number_enable_r=1'b0;
                            string_id_r=8'd10;
                        end
                    end
                    6'd8:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd82,5'd9,4'd15};
                        number_enable_r = 1'b1;
                        number_value_r = {8'd0,bend_delta};
                        number_scale_r = 3'd5;
                        font_style_r = 2'd3;
                        decimal_places_r = 3'd0;
                        suffix_r = 4'd8;
                        negative_r = bend_negative;
                        sign_mode_r = 2'd1;
                        minimum_digits_r = 3'd1;
                        if (!s[508])
                        begin
                            number_enable_r=1'b0;
                            string_id_r=8'd11;
                        end
                    end
                    6'd9:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd82,5'd13,4'd15};
                        number_enable_r = 1'b1;
                        number_value_r = {8'd0,output_peak};
                        number_scale_r = 3'd1;
                        font_style_r = 2'd3;
                        decimal_places_r = 3'd2;
                        suffix_r = 4'd7;
                        negative_r = 1'b0;
                        sign_mode_r = 2'd0;
                        minimum_digits_r = 3'd3;
                        if (!pcm_valid)
                        begin
                            number_enable_r=1'b0;
                            string_id_r=8'd12;
                        end
                    end
                    6'd10:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd82,5'd16,((fft_overflow || spectrum_clipped || !graph_valid) ? 4'd14 : 4'd13)};
                        string_id_r = fft_overflow ? 8'd13 : spectrum_clipped ? 8'd14 : graph_valid ? 8'd15 : 8'd16;
                    end
                    6'd11:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd82,5'd18,4'd12};
                        string_id_r = (reset_visible != 22'd0) ? 8'd17 : min_hit ? 8'd18 : 8'd0;
                    end
                    6'd12:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd5,5'd20,4'd11};
                        string_id_r = 8'd20;
                    end
                    6'd13:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd39,5'd20,4'd11};
                        string_id_r = view ? 8'd21 : 8'd22;
                    end
                    6'd14:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {(view ? 7'd70 : 7'd67),5'd20,4'd11};
                        string_id_r = view ? 8'd23 : 8'd24;
                    end
                    6'd15:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd21,5'd20,4'd11};
                        string_id_r = view ? 8'd25 : 8'd0;
                    end
                    6'd16:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd57,5'd20,4'd11};
                        string_id_r = view ? 8'd26 : 8'd0;
                    end
                    6'd17:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd1,5'd5,4'd11};
                        string_id_r = view ? 8'd27 : 8'd28;
                    end
                    6'd18:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd1,5'd20,4'd11};
                        string_id_r = view ? 8'd29 : 8'd30;
                    end
                    6'd19:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd2,5'd12,4'd11};
                        string_id_r = view ? 8'd0 : 8'd31;
                    end
                    6'd20:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd24,5'd11,4'd11};
                        string_id_r = graph_valid ? 8'd0 : view ? 8'd32 : 8'd33;
                    end
                    6'd21:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd3,5'd28,4'd11};
                        string_id_r = 8'd34;
                    end
                    6'd22:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd27,5'd28,4'd11};
                        string_id_r = 8'd35;
                    end
                    6'd23:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd51,5'd28,4'd11};
                        string_id_r = 8'd36;
                    end
                    6'd24:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd75,5'd28,4'd11};
                        string_id_r = 8'd37;
                    end
                    6'd25:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd4,5'd22,4'd11};
                        string_id_r = mode1 ? 8'd38 : 8'd39;
                    end
                    6'd26:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd4,5'd23,active_cards[0] ? 4'd12 : 4'd15};
                        string_id_r = ((wave_number == 3'd0) ? 8'd40 : (wave_number == 3'd1) ? 8'd41 : (wave_number == 3'd2) ? 8'd42 : 8'd43);
                    end
                    6'd27:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd28,5'd22,4'd11};
                        string_id_r = mode1 ? 8'd44 : 8'd45;
                    end
                    6'd28:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd28,5'd23,active_cards[1] ? 4'd12 : 4'd15};
                        number_enable_r = 1'b1;
                        number_value_r = (mode1 ? base(3) : base(2));
                        number_scale_r = 3'd0;
                        font_style_r = 2'd1;
                        decimal_places_r = 3'd0;
                        suffix_r = 4'd0;
                        negative_r = 1'b0;
                        sign_mode_r = 2'd0;
                        minimum_digits_r = 3'd1;
                        suffix_r = (mode1 ? 4'd4 : 4'd1);
                    end
                    6'd29:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd52,5'd22,4'd11};
                        string_id_r = mode1 ? 8'd46 : 8'd46;
                    end
                    6'd30:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd52,5'd23,active_cards[2] ? 4'd12 : 4'd15};
                        number_enable_r = 1'b1;
                        number_value_r = s[239:224];
                        number_scale_r = 3'd1;
                        font_style_r = 2'd1;
                        decimal_places_r = 3'd2;
                        suffix_r = 4'd0;
                        negative_r = 1'b0;
                        sign_mode_r = 2'd0;
                        minimum_digits_r = 3'd3;
                        suffix_r = 4'd3;
                    end
                    6'd31:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd76,5'd22,4'd11};
                        string_id_r = mode1 ? 8'd47 : 8'd47;
                    end
                    6'd32:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd76,5'd23,active_cards[3] ? 4'd12 : 4'd15};
                        number_enable_r = 1'b1;
                        number_value_r = s[255:240];
                        number_scale_r = 3'd1;
                        font_style_r = 2'd1;
                        decimal_places_r = 3'd2;
                        suffix_r = 4'd0;
                        negative_r = 1'b0;
                        sign_mode_r = 2'd0;
                        minimum_digits_r = 3'd3;
                        suffix_r = 4'd3;
                    end
                    6'd33:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd4,5'd25,4'd11};
                        string_id_r = mode1 ? 8'd48 : 8'd49;
                    end
                    6'd34:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd4,5'd26,active_cards[4] ? 4'd12 : 4'd15};
                        number_enable_r = 1'b1;
                        number_value_r = (mode1 ? base(8) : base(4));
                        number_scale_r = 3'd0;
                        font_style_r = 2'd1;
                        decimal_places_r = 3'd0;
                        suffix_r = 4'd0;
                        negative_r = 1'b0;
                        sign_mode_r = 2'd0;
                        minimum_digits_r = 3'd1;
                        suffix_r = (mode1 ? 4'd1 : 4'd2);
                    end
                    6'd35:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd28,5'd25,4'd11};
                        string_id_r = mode1 ? 8'd50 : 8'd51;
                    end
                    6'd36:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd28,5'd26,active_cards[5] ? 4'd12 : 4'd15};
                        number_enable_r = 1'b1;
                        number_value_r = (mode1 ? base(9) : base(5));
                        number_scale_r = 3'd0;
                        font_style_r = 2'd1;
                        decimal_places_r = 3'd0;
                        suffix_r = 4'd0;
                        negative_r = 1'b0;
                        sign_mode_r = 2'd0;
                        minimum_digits_r = 3'd1;
                        suffix_r = (mode1 ? 4'd1 : 4'd2);
                    end
                    6'd37:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd52,5'd25,4'd11};
                        string_id_r = mode1 ? 8'd52 : 8'd53;
                    end
                    6'd38:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd52,5'd26,active_cards[6] ? 4'd12 : 4'd15};
                        number_enable_r = 1'b1;
                        number_value_r = (mode1 ? base(10) : base(6));
                        number_scale_r = 3'd0;
                        font_style_r = 2'd1;
                        decimal_places_r = 3'd0;
                        suffix_r = 4'd0;
                        negative_r = 1'b0;
                        sign_mode_r = 2'd0;
                        minimum_digits_r = 3'd1;
                        suffix_r = 4'd1;
                    end
                    6'd39:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd76,5'd25,4'd11};
                        string_id_r = mode1 ? 8'd54 : 8'd55;
                    end
                    6'd40:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd76,5'd26,active_cards[7] ? 4'd12 : 4'd15};
                        number_enable_r = 1'b1;
                        number_value_r = (mode1 ? base(11) : base(7));
                        number_scale_r = 3'd0;
                        font_style_r = 2'd1;
                        decimal_places_r = 3'd0;
                        suffix_r = 4'd0;
                        negative_r = 1'b0;
                        sign_mode_r = 2'd0;
                        minimum_digits_r = 3'd1;
                        suffix_r = (mode1 ? 4'd1 : 4'd2);
                    end
                    6'd41:
                    begin
                        if (step_active && reset_visible == 22'd0 && !min_hit && s[415:400] != 16'd0)
                        begin
                            {object_col_r,object_row_r,object_color_r} = {7'd82,5'd18,4'd12};
                            string_id_r = 8'd56;
                        end
                    end
                    6'd42:
                    begin
                        if (step_active && reset_visible == 22'd0 && !min_hit && s[415:400] != 16'd0)
                        begin
                            {object_col_r,object_row_r,object_color_r} = {7'd86,5'd18,4'd12};
                            number_enable_r = 1'b1;
                            number_value_r = progress_abs;
                            number_scale_r = 3'd0;
                            font_style_r = 2'd0;
                            decimal_places_r = 3'd0;
                            suffix_r = 4'd0;
                            negative_r = s[399];
                            sign_mode_r = 2'd2;
                            minimum_digits_r = 3'd1;
                        end
                    end
                    6'd43:
                    begin
                        if (step_active && reset_visible == 22'd0 && !min_hit && s[415:400] != 16'd0)
                        begin
                            {object_col_r,object_row_r,object_color_r} = {7'd92,5'd18,4'd12};
                            string_id_r = 8'd57;
                        end
                    end
                    6'd44:
                    begin
                        if (step_active && reset_visible == 22'd0 && !min_hit && s[415:400] != 16'd0)
                        begin
                            {object_col_r,object_row_r,object_color_r} = {7'd93,5'd18,4'd12};
                            number_enable_r = 1'b1;
                            number_value_r = {8'd0,s[415:400]};
                            number_scale_r = 3'd0;
                            font_style_r = 2'd0;
                            decimal_places_r = 3'd0;
                            suffix_r = 4'd0;
                            negative_r = 1'b0;
                            sign_mode_r = 2'd0;
                            minimum_digits_r = 3'd1;
                        end
                    end
                    6'd45:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd84,5'd1,4'd12};
                        string_id_r = s[509] ? 8'd144 : 8'd145;
                    end
                    default: object_valid_r=1'b0;
                endcase
            end
            4'd1:
            begin
                case (object_index)
                    6'd0:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd3,5'd0,4'd15};
                        string_id_r = 8'd1;
                    end
                    6'd1:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd19,5'd0,4'd15};
                        string_id_r = 8'd58;
                    end
                    6'd2:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd5,5'd4,4'd15};
                        string_id_r = 8'd59;
                    end
                    6'd3:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd6,5'd10,4'd11};
                        string_id_r = 8'd60;
                    end
                    6'd4:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd12,5'd10,4'd15};
                        string_id_r = 8'd61;
                    end
                    6'd5:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd6,5'd14,4'd11};
                        string_id_r = 8'd62;
                    end
                    6'd6:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd12,5'd14,4'd15};
                        string_id_r = 8'd63;
                    end
                    6'd7:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd6,5'd18,4'd11};
                        string_id_r = 8'd64;
                    end
                    6'd8:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd12,5'd18,4'd15};
                        string_id_r = 8'd65;
                    end
                    6'd9:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd6,5'd22,4'd11};
                        string_id_r = 8'd66;
                    end
                    6'd10:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd12,5'd22,4'd15};
                        string_id_r = 8'd67;
                    end
                    6'd11:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd3,5'd28,4'd11};
                        string_id_r = 8'd68;
                    end
                    6'd12:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd27,5'd28,4'd11};
                        string_id_r = 8'd69;
                    end
                    6'd13:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd51,5'd28,4'd11};
                        string_id_r = 8'd70;
                    end
                    6'd14:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd75,5'd28,4'd11};
                        string_id_r = 8'd71;
                    end
                    default: object_valid_r=1'b0;
                endcase
            end
            4'd6:
            begin
                case (object_index)
                    6'd0:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd3,5'd0,4'd15};
                        string_id_r = 8'd1;
                    end
                    6'd1:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd19,5'd0,4'd15};
                        string_id_r = 8'd58;
                    end
                    6'd2:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd5,5'd4,4'd15};
                        string_id_r = 8'd72;
                    end
                    6'd3:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd6,5'd10,4'd11};
                        string_id_r = 8'd60;
                    end
                    6'd4:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd12,5'd10,4'd15};
                        string_id_r = 8'd73;
                    end
                    6'd5:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd6,5'd14,4'd11};
                        string_id_r = 8'd62;
                    end
                    6'd6:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd12,5'd14,4'd15};
                        string_id_r = 8'd74;
                    end
                    6'd7:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd6,5'd18,4'd11};
                        string_id_r = 8'd64;
                    end
                    6'd8:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd12,5'd18,4'd15};
                        string_id_r = 8'd75;
                    end
                    6'd9:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd6,5'd22,4'd11};
                        string_id_r = 8'd66;
                    end
                    6'd10:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd12,5'd22,4'd15};
                        string_id_r = 8'd76;
                    end
                    6'd11:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd3,5'd28,4'd11};
                        string_id_r = 8'd68;
                    end
                    6'd12:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd27,5'd28,4'd11};
                        string_id_r = 8'd69;
                    end
                    6'd13:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd51,5'd28,4'd11};
                        string_id_r = 8'd70;
                    end
                    6'd14:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd75,5'd28,4'd11};
                        string_id_r = 8'd71;
                    end
                    default: object_valid_r=1'b0;
                endcase
            end
            4'd2:
            begin
                case (object_index)
                    6'd0:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd3,5'd0,4'd15};
                        string_id_r = 8'd1;
                    end
                    6'd1:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd19,5'd0,4'd15};
                        string_id_r = 8'd93;
                    end
                    6'd2:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd4,5'd4,4'd15};
                        string_id_r = save ? 8'd94 : 8'd95;
                    end
                    6'd3:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd82,5'd4,4'd11};
                        string_id_r = s[437] ? ((slot == 5'd0) ? 8'd77 : (slot == 5'd1) ? 8'd78 : (slot == 5'd2) ? 8'd79 : (slot == 5'd3) ? 8'd80 : (slot == 5'd4) ? 8'd81 : (slot == 5'd5) ? 8'd82 : (slot == 5'd6) ? 8'd83 : (slot == 5'd7) ? 8'd84 : (slot == 5'd8) ? 8'd85 : (slot == 5'd9) ? 8'd86 : (slot == 5'd10) ? 8'd87 : (slot == 5'd11) ? 8'd88 : (slot == 5'd12) ? 8'd89 : (slot == 5'd13) ? 8'd90 : (slot == 5'd14) ? 8'd91 : 8'd92) : 8'd96;
                    end
                    6'd4:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd5,5'd8,4'd15};
                        string_id_r = 8'd77;
                    end
                    6'd5:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd34,5'd8,4'd11};
                        string_id_r = !s[437] ? 8'd97 : s[438] ? 8'd98 : 8'd99;
                    end
                    6'd6:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd5,5'd10,4'd15};
                        string_id_r = 8'd78;
                    end
                    6'd7:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd34,5'd10,4'd11};
                        string_id_r = !s[437] ? 8'd97 : s[439] ? 8'd98 : 8'd99;
                    end
                    6'd8:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd5,5'd12,4'd15};
                        string_id_r = 8'd79;
                    end
                    6'd9:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd34,5'd12,4'd11};
                        string_id_r = !s[437] ? 8'd97 : s[440] ? 8'd98 : 8'd99;
                    end
                    6'd10:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd5,5'd14,4'd15};
                        string_id_r = 8'd80;
                    end
                    6'd11:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd34,5'd14,4'd11};
                        string_id_r = !s[437] ? 8'd97 : s[441] ? 8'd98 : 8'd99;
                    end
                    6'd12:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd5,5'd16,4'd15};
                        string_id_r = 8'd81;
                    end
                    6'd13:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd34,5'd16,4'd11};
                        string_id_r = !s[437] ? 8'd97 : s[442] ? 8'd98 : 8'd99;
                    end
                    6'd14:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd5,5'd18,4'd15};
                        string_id_r = 8'd82;
                    end
                    6'd15:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd34,5'd18,4'd11};
                        string_id_r = !s[437] ? 8'd97 : s[443] ? 8'd98 : 8'd99;
                    end
                    6'd16:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd5,5'd20,4'd15};
                        string_id_r = 8'd83;
                    end
                    6'd17:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd34,5'd20,4'd11};
                        string_id_r = !s[437] ? 8'd97 : s[444] ? 8'd98 : 8'd99;
                    end
                    6'd18:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd5,5'd22,4'd15};
                        string_id_r = 8'd84;
                    end
                    6'd19:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd34,5'd22,4'd11};
                        string_id_r = !s[437] ? 8'd97 : s[445] ? 8'd98 : 8'd99;
                    end
                    6'd20:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd53,5'd8,4'd15};
                        string_id_r = 8'd85;
                    end
                    6'd21:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd82,5'd8,4'd11};
                        string_id_r = !s[437] ? 8'd97 : s[446] ? 8'd98 : 8'd99;
                    end
                    6'd22:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd53,5'd10,4'd15};
                        string_id_r = 8'd86;
                    end
                    6'd23:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd82,5'd10,4'd11};
                        string_id_r = !s[437] ? 8'd97 : s[447] ? 8'd98 : 8'd99;
                    end
                    6'd24:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd53,5'd12,4'd15};
                        string_id_r = 8'd87;
                    end
                    6'd25:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd82,5'd12,4'd11};
                        string_id_r = !s[437] ? 8'd97 : s[448] ? 8'd98 : 8'd99;
                    end
                    6'd26:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd53,5'd14,4'd15};
                        string_id_r = 8'd88;
                    end
                    6'd27:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd82,5'd14,4'd11};
                        string_id_r = !s[437] ? 8'd97 : s[449] ? 8'd98 : 8'd99;
                    end
                    6'd28:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd53,5'd16,4'd15};
                        string_id_r = 8'd89;
                    end
                    6'd29:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd82,5'd16,4'd11};
                        string_id_r = !s[437] ? 8'd97 : s[450] ? 8'd98 : 8'd99;
                    end
                    6'd30:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd53,5'd18,4'd15};
                        string_id_r = 8'd90;
                    end
                    6'd31:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd82,5'd18,4'd11};
                        string_id_r = !s[437] ? 8'd97 : s[451] ? 8'd98 : 8'd99;
                    end
                    6'd32:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd53,5'd20,4'd15};
                        string_id_r = 8'd91;
                    end
                    6'd33:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd82,5'd20,4'd11};
                        string_id_r = !s[437] ? 8'd97 : s[452] ? 8'd98 : 8'd99;
                    end
                    6'd34:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd53,5'd22,4'd15};
                        string_id_r = 8'd92;
                    end
                    6'd35:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd82,5'd22,4'd11};
                        string_id_r = !s[437] ? 8'd97 : s[453] ? 8'd98 : 8'd99;
                    end
                    6'd36:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd3,5'd28,4'd11};
                        string_id_r = 8'd100;
                    end
                    6'd37:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd27,5'd28,4'd11};
                        string_id_r = 8'd101;
                    end
                    6'd38:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd51,5'd28,4'd11};
                        string_id_r = 8'd102;
                    end
                    6'd39:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd75,5'd28,4'd11};
                        string_id_r = 8'd103;
                    end
                    default: object_valid_r=1'b0;
                endcase
            end
            4'd3:
            begin
                case (object_index)
                    6'd0:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd3,5'd0,4'd15};
                        string_id_r = 8'd1;
                    end
                    6'd1:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd19,5'd0,4'd15};
                        string_id_r = 8'd93;
                    end
                    6'd2:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd45,5'd10,4'd11};
                        string_id_r = ((slot == 5'd0) ? 8'd77 : (slot == 5'd1) ? 8'd78 : (slot == 5'd2) ? 8'd79 : (slot == 5'd3) ? 8'd80 : (slot == 5'd4) ? 8'd81 : (slot == 5'd5) ? 8'd82 : (slot == 5'd6) ? 8'd83 : (slot == 5'd7) ? 8'd84 : (slot == 5'd8) ? 8'd85 : (slot == 5'd9) ? 8'd86 : (slot == 5'd10) ? 8'd87 : (slot == 5'd11) ? 8'd88 : (slot == 5'd12) ? 8'd89 : (slot == 5'd13) ? 8'd90 : (slot == 5'd14) ? 8'd91 : 8'd92);
                    end
                    6'd3:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {(!save ? 7'd43 : (!s[437] || s[438+slot]) ? 7'd36 : 7'd44),5'd13,message_color};
                        string_id_r = !save ? 8'd104 : (!s[437] || s[438+slot]) ? 8'd105 : 8'd106;
                    end
                    6'd4:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd42,5'd17,4'd14};
                        string_id_r = save && !s[437] ? 8'd107 : 8'd0;
                    end
                    6'd5:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd3,5'd28,4'd11};
                        string_id_r = 8'd108;
                    end
                    6'd6:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd75,5'd28,4'd11};
                        string_id_r = 8'd109;
                    end
                    default: object_valid_r=1'b0;
                endcase
            end
            4'd4:
            begin
                case (object_index)
                    6'd0:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd3,5'd0,4'd15};
                        string_id_r = 8'd1;
                    end
                    6'd1:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd19,5'd0,4'd15};
                        string_id_r = 8'd93;
                    end
                    6'd2:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd45,5'd10,4'd11};
                        string_id_r = ((slot == 5'd0) ? 8'd77 : (slot == 5'd1) ? 8'd78 : (slot == 5'd2) ? 8'd79 : (slot == 5'd3) ? 8'd80 : (slot == 5'd4) ? 8'd81 : (slot == 5'd5) ? 8'd82 : (slot == 5'd6) ? 8'd83 : (slot == 5'd7) ? 8'd84 : (slot == 5'd8) ? 8'd85 : (slot == 5'd9) ? 8'd86 : (slot == 5'd10) ? 8'd87 : (slot == 5'd11) ? 8'd88 : (slot == 5'd12) ? 8'd89 : (slot == 5'd13) ? 8'd90 : (slot == 5'd14) ? 8'd91 : 8'd92);
                    end
                    6'd3:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd40,5'd13,message_color};
                        string_id_r = save ? 8'd110 : 8'd111;
                    end
                    default: object_valid_r=1'b0;
                endcase
            end
            4'd5:
            begin
                case (object_index)
                    6'd0:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd3,5'd0,4'd15};
                        string_id_r = 8'd1;
                    end
                    6'd1:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd19,5'd0,4'd15};
                        string_id_r = 8'd93;
                    end
                    6'd2:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd45,5'd10,4'd11};
                        string_id_r = ((slot == 5'd0) ? 8'd77 : (slot == 5'd1) ? 8'd78 : (slot == 5'd2) ? 8'd79 : (slot == 5'd3) ? 8'd80 : (slot == 5'd4) ? 8'd81 : (slot == 5'd5) ? 8'd82 : (slot == 5'd6) ? 8'd83 : (slot == 5'd7) ? 8'd84 : (slot == 5'd8) ? 8'd85 : (slot == 5'd9) ? 8'd86 : (slot == 5'd10) ? 8'd87 : (slot == 5'd11) ? 8'd88 : (slot == 5'd12) ? 8'd89 : (slot == 5'd13) ? 8'd90 : (slot == 5'd14) ? 8'd91 : 8'd92);
                    end
                    6'd3:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd40,5'd13,message_color};
                        string_id_r = result_ok ? (save ? 8'd112 : 8'd113) : 8'd114;
                    end
                    6'd4:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd39,5'd17,4'd15};
                        string_id_r = ((error_index == 4'd0) ? 8'd115 : (error_index == 4'd1) ? 8'd116 : (error_index == 4'd2) ? 8'd117 : (error_index == 4'd3) ? 8'd118 : (error_index == 4'd4) ? 8'd119 : (error_index == 4'd5) ? 8'd120 : (error_index == 4'd6) ? 8'd121 : 8'd122);
                    end
                    6'd5:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd3,5'd28,4'd11};
                        string_id_r = 8'd123;
                    end
                    6'd6:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd75,5'd28,4'd11};
                        string_id_r = 8'd124;
                    end
                    default: object_valid_r=1'b0;
                endcase
            end
            4'd7:
            begin
                case (object_index)
                    6'd0:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd3,5'd0,4'd15};
                        string_id_r = 8'd1;
                    end
                    6'd1:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd19,5'd0,4'd15};
                        string_id_r = 8'd125;
                    end
                    6'd2:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd4,5'd4,4'd15};
                        string_id_r = ((effect == 3'd0) ? 8'd126 : (effect == 3'd1) ? 8'd127 : (effect == 3'd2) ? 8'd128 : 8'd129);
                    end
                    6'd3:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd81,5'd4,4'd11};
                        string_id_r = 8'd130;
                    end
                    6'd4:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd87,5'd4,4'd15};
                        number_enable_r = 1'b1;
                        number_value_r = effect_mix;
                        number_scale_r = 3'd0;
                        font_style_r = 2'd1;
                        decimal_places_r = 3'd0;
                        suffix_r = 4'd1;
                        negative_r = 1'b0;
                        sign_mode_r = 2'd0;
                        minimum_digits_r = 3'd1;
                    end
                    6'd5:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd5,5'd9,4'd11};
                        string_id_r = ((effect == 3'd0) ? 8'd131 : (effect == 3'd1) ? 8'd132 : (effect == 3'd2) ? 8'd133 : 8'd134);
                    end
                    6'd6:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd5,5'd12,4'd15};
                        number_enable_r = 1'b1;
                        number_value_r = advanced_value_0;
                        number_scale_r = 3'd0;
                        font_style_r = 2'd2;
                        decimal_places_r = 3'd4;
                        suffix_r = 4'd0;
                        negative_r = 1'b0;
                        sign_mode_r = 2'd0;
                        minimum_digits_r = 3'd5;
                        number_scale_r=advanced_scale_0;
                        decimal_places_r=advanced_decimal_0;
                        minimum_digits_r=(advanced_decimal_0 == 0) ? 3'd1 : 3'd5;
                        suffix_r=advanced_suffix_0;
                    end
                    6'd7:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd53,5'd9,4'd11};
                        string_id_r = ((effect == 3'd0) ? 8'd135 : (effect == 3'd1) ? 8'd136 : (effect == 3'd2) ? 8'd137 : 8'd138);
                    end
                    6'd8:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd53,5'd12,4'd15};
                        number_enable_r = 1'b1;
                        number_value_r = advanced_value_1;
                        number_scale_r = 3'd0;
                        font_style_r = 2'd2;
                        decimal_places_r = 3'd4;
                        suffix_r = 4'd0;
                        negative_r = 1'b0;
                        sign_mode_r = 2'd0;
                        minimum_digits_r = 3'd5;
                        number_scale_r=advanced_scale_1;
                        decimal_places_r=advanced_decimal_1;
                        minimum_digits_r=(advanced_decimal_1 == 0) ? 3'd1 : 3'd5;
                        suffix_r=advanced_suffix_1;
                    end
                    6'd9:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd6,5'd23,s[436] ? 4'd14 : 4'd12};
                        string_id_r = s[436] ? 8'd139 : 8'd140;
                    end
                    6'd14:
                    begin
                        // K4: gain compensation after the selected effect's dry/wet mix.
                        if (s[544]) begin
                            {object_col_r,object_row_r,object_color_r} = {7'd5,5'd17,4'd11};
                            string_id_r = 8'd133;
                        end else object_valid_r = 1'b0;
                    end
                    6'd15:
                    begin
                        if (s[544]) begin
                            {object_col_r,object_row_r,object_color_r} = {7'd5,5'd20,4'd15};
                            number_enable_r = 1'b1;
                            number_value_r = {8'd0,s[543:528]};
                            number_scale_r = 3'd6;
                            font_style_r = 2'd2;
                            decimal_places_r = 3'd4;
                            minimum_digits_r = 3'd5;
                        end else object_valid_r = 1'b0;
                    end
                    6'd10:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd3,5'd28,4'd11};
                        string_id_r = 8'd108;
                    end
                    6'd11:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd27,5'd28,4'd11};
                        string_id_r = 8'd141;
                    end
                    6'd12:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd51,5'd28,4'd11};
                        string_id_r = 8'd142;
                    end
                    6'd13:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd75,5'd28,4'd11};
                        string_id_r = 8'd143;
                    end
                    default: object_valid_r=1'b0;
                endcase
            end
            4'd9:
            begin
                case (object_index)
                    6'd0:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd3,5'd0,4'd15};
                        string_id_r = 8'd1;
                    end
                    6'd1:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd19,5'd0,4'd15};
                        string_id_r = 8'd58;
                    end
                    6'd2:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd5,5'd4,4'd15};
                        string_id_r = 8'd146;
                    end
                    6'd3:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd6,5'd10,4'd11};
                        string_id_r = 8'd60;
                    end
                    6'd4:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd12,5'd10,4'd15};
                        string_id_r = 8'd147;
                    end
                    6'd5:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd6,5'd14,4'd11};
                        string_id_r = 8'd62;
                    end
                    6'd6:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd12,5'd14,4'd15};
                        string_id_r = 8'd148;
                    end
                    6'd7:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd3,5'd28,4'd11};
                        string_id_r = 8'd108;
                    end
                    6'd8:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd27,5'd28,4'd11};
                        string_id_r = 8'd149;
                    end
                    6'd9:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd51,5'd28,4'd11};
                        string_id_r = 8'd150;
                    end
                    6'd10:
                    begin
                        {object_col_r,object_row_r,object_color_r} = {7'd75,5'd28,4'd11};
                        string_id_r = 8'd71;
                    end
                    default: object_valid_r=1'b0;
                endcase
            end
            default: object_valid_r=1'b0;
        endcase
    end
endmodule
