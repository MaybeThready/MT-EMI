/**
 * 固定16色调色板，将4位无符号像素索引转换为RGB666的{R,G,B}。
 * 纯组合查询，不涉及Q格式，也不增加时钟周期延迟。
 * 扫描期间调色板固定，索引0..7同时兼容旧版色条。
 */
module lcd_palette
(
    input [3:0] pixel_index,
    output [17:0] pixel_rgb
);
    reg [17:0] pixel_rgb_r;
    assign pixel_rgb = pixel_rgb_r;

    always @(*)
    begin
        case (pixel_index)
            4'd0: pixel_rgb_r = {6'd0, 6'd0, 6'd0};
            4'd1: pixel_rgb_r = {6'd63, 6'd63, 6'd63};
            4'd2: pixel_rgb_r = {6'd63, 6'd63, 6'd0};
            4'd3: pixel_rgb_r = {6'd0, 6'd63, 6'd63};
            4'd4: pixel_rgb_r = {6'd0, 6'd63, 6'd0};
            4'd5: pixel_rgb_r = {6'd63, 6'd0, 6'd63};
            4'd6: pixel_rgb_r = {6'd63, 6'd0, 6'd0};
            4'd7: pixel_rgb_r = {6'd0, 6'd0, 6'd63};
            4'd8: pixel_rgb_r = {6'd4, 6'd6, 6'd8};
            4'd9: pixel_rgb_r = {6'd6, 6'd9, 6'd12};
            4'd10: pixel_rgb_r = {6'd10, 6'd16, 6'd19};
            4'd11: pixel_rgb_r = {6'd38, 6'd43, 6'd46};
            4'd12: pixel_rgb_r = {6'd20, 6'd54, 6'd55};
            4'd13: pixel_rgb_r = {6'd40, 6'd56, 6'd26};
            4'd14: pixel_rgb_r = {6'd63, 6'd51, 6'd25};
            4'd15: pixel_rgb_r = {6'd57, 6'd59, 6'd60};
            default: pixel_rgb_r = 18'd0;
        endcase
    end
endmodule
