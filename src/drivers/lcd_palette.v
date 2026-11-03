/**
 * 第四版RGB666调色板；phase与像素索引同拍输入，纯组合逻辑ROM。
 * 仅声音强调色循环，背景、白色文字和告警色固定；不使用DSP/BSRAM。
 */
module lcd_palette (input wire [3:0] pixel_index, input wire [3:0] phase, output wire [17:0] pixel_rgb) /* synthesis syn_romstyle = "logic" */;
    reg [17:0] rgb_r;
    assign pixel_rgb=rgb_r;
    always @(*)
    begin
        case (pixel_index)
            4'd0: rgb_r={6'd0,6'd0,6'd0};
            4'd5: rgb_r={6'd10,6'd6,6'd17};
            4'd6: rgb_r={6'd63,6'd53,6'd20};
            4'd7: rgb_r={6'd10,6'd15,6'd22};
            4'd8: rgb_r={6'd3,6'd5,6'd8};
            4'd9: rgb_r={6'd5,6'd8,6'd13};
            4'd10: rgb_r={6'd9,6'd14,6'd21};
            4'd11: rgb_r={6'd34,6'd42,6'd49};
            4'd13: rgb_r={6'd37,6'd57,6'd26};
            4'd14: rgb_r={6'd63,6'd33,6'd25};
            4'd15: rgb_r={6'd57,6'd60,6'd63};
            4'd12:
            begin
                case (phase)
                    4'd0: rgb_r={6'd18,6'd59,6'd57};
                    4'd1: rgb_r={6'd18,6'd59,6'd59};
                    4'd2: rgb_r={6'd18,6'd57,6'd59};
                    4'd3: rgb_r={6'd18,6'd54,6'd59};
                    4'd4: rgb_r={6'd18,6'd52,6'd59};
                    4'd5: rgb_r={6'd18,6'd54,6'd59};
                    4'd6: rgb_r={6'd18,6'd57,6'd59};
                    4'd7: rgb_r={6'd18,6'd59,6'd59};
                    4'd8: rgb_r={6'd18,6'd59,6'd57};
                    4'd9: rgb_r={6'd18,6'd59,6'd54};
                    4'd10: rgb_r={6'd18,6'd59,6'd52};
                    4'd11: rgb_r={6'd18,6'd59,6'd49};
                    4'd12: rgb_r={6'd18,6'd59,6'd47};
                    4'd13: rgb_r={6'd18,6'd59,6'd49};
                    4'd14: rgb_r={6'd18,6'd59,6'd52};
                    4'd15: rgb_r={6'd18,6'd59,6'd54};
                    default: rgb_r=18'd0;
                endcase
            end
            4'd1:
            begin
                case (phase)
                    4'd0: rgb_r={6'd16,6'd35,6'd63};
                    4'd1: rgb_r={6'd16,6'd32,6'd63};
                    4'd2: rgb_r={6'd16,6'd29,6'd63};
                    4'd3: rgb_r={6'd16,6'd26,6'd63};
                    4'd4: rgb_r={6'd16,6'd23,6'd63};
                    4'd5: rgb_r={6'd16,6'd26,6'd63};
                    4'd6: rgb_r={6'd16,6'd29,6'd63};
                    4'd7: rgb_r={6'd16,6'd32,6'd63};
                    4'd8: rgb_r={6'd16,6'd35,6'd63};
                    4'd9: rgb_r={6'd16,6'd37,6'd63};
                    4'd10: rgb_r={6'd16,6'd40,6'd63};
                    4'd11: rgb_r={6'd16,6'd43,6'd63};
                    4'd12: rgb_r={6'd16,6'd46,6'd63};
                    4'd13: rgb_r={6'd16,6'd43,6'd63};
                    4'd14: rgb_r={6'd16,6'd40,6'd63};
                    4'd15: rgb_r={6'd16,6'd37,6'd63};
                    default: rgb_r=18'd0;
                endcase
            end
            4'd2:
            begin
                case (phase)
                    4'd0: rgb_r={6'd39,6'd25,6'd62};
                    4'd1: rgb_r={6'd41,6'd25,6'd62};
                    4'd2: rgb_r={6'd43,6'd25,6'd62};
                    4'd3: rgb_r={6'd45,6'd25,6'd62};
                    4'd4: rgb_r={6'd48,6'd25,6'd62};
                    4'd5: rgb_r={6'd45,6'd25,6'd62};
                    4'd6: rgb_r={6'd43,6'd25,6'd62};
                    4'd7: rgb_r={6'd41,6'd25,6'd62};
                    4'd8: rgb_r={6'd39,6'd25,6'd62};
                    4'd9: rgb_r={6'd37,6'd25,6'd62};
                    4'd10: rgb_r={6'd34,6'd25,6'd62};
                    4'd11: rgb_r={6'd32,6'd25,6'd62};
                    4'd12: rgb_r={6'd30,6'd25,6'd62};
                    4'd13: rgb_r={6'd32,6'd25,6'd62};
                    4'd14: rgb_r={6'd34,6'd25,6'd62};
                    4'd15: rgb_r={6'd37,6'd25,6'd62};
                    default: rgb_r=18'd0;
                endcase
            end
            4'd3:
            begin
                case (phase)
                    4'd0: rgb_r={6'd62,6'd26,6'd52};
                    4'd1: rgb_r={6'd62,6'd26,6'd50};
                    4'd2: rgb_r={6'd62,6'd26,6'd47};
                    4'd3: rgb_r={6'd62,6'd26,6'd45};
                    4'd4: rgb_r={6'd62,6'd26,6'd43};
                    4'd5: rgb_r={6'd62,6'd26,6'd45};
                    4'd6: rgb_r={6'd62,6'd26,6'd47};
                    4'd7: rgb_r={6'd62,6'd26,6'd50};
                    4'd8: rgb_r={6'd62,6'd26,6'd52};
                    4'd9: rgb_r={6'd62,6'd26,6'd54};
                    4'd10: rgb_r={6'd62,6'd26,6'd56};
                    4'd11: rgb_r={6'd62,6'd26,6'd58};
                    4'd12: rgb_r={6'd62,6'd26,6'd60};
                    4'd13: rgb_r={6'd62,6'd26,6'd58};
                    4'd14: rgb_r={6'd62,6'd26,6'd56};
                    4'd15: rgb_r={6'd62,6'd26,6'd54};
                    default: rgb_r=18'd0;
                endcase
            end
            4'd4:
            begin
                case (phase)
                    4'd0: rgb_r={6'd7,6'd19,6'd18};
                    4'd1: rgb_r={6'd7,6'd19,6'd19};
                    4'd2: rgb_r={6'd7,6'd18,6'd19};
                    4'd3: rgb_r={6'd7,6'd17,6'd19};
                    4'd4: rgb_r={6'd7,6'd17,6'd19};
                    4'd5: rgb_r={6'd7,6'd17,6'd19};
                    4'd6: rgb_r={6'd7,6'd18,6'd19};
                    4'd7: rgb_r={6'd7,6'd19,6'd19};
                    4'd8: rgb_r={6'd7,6'd19,6'd18};
                    4'd9: rgb_r={6'd7,6'd19,6'd17};
                    4'd10: rgb_r={6'd7,6'd19,6'd17};
                    4'd11: rgb_r={6'd7,6'd19,6'd16};
                    4'd12: rgb_r={6'd7,6'd19,6'd15};
                    4'd13: rgb_r={6'd7,6'd19,6'd16};
                    4'd14: rgb_r={6'd7,6'd19,6'd17};
                    4'd15: rgb_r={6'd7,6'd19,6'd17};
                    default: rgb_r=18'd0;
                endcase
            end
            default: rgb_r=18'd0;
        endcase
    end
endmodule
