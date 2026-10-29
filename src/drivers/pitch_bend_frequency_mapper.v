/**
 * 单音弯音频率换算：33 点比率表与线性插值，实现 -200..+200 音分。
 * 这是供 UI 调用的独立辅助模块，不改变 pitch_bend_driver 的位置输出接口。
 */

/**
 * clk_sys / rst_n: 系统时钟 / 低有效异步复位。
 * base_freq / note_freq: 基准 / 弯音后频率，均为 32 位 UQ16.16，单位 Hz。
 * bend_value: UQ0.16 位置；0000=-200 音分，8000=0，FFFF=+200 音分。
 * in_valid && in_ready: 上升沿锁存一组频率与位置，计算期间无需保持输入。
 * out_valid && out_ready: 上升沿交付结果，背压期间保持输出；超范围饱和为 FFFFFFFF。
 * 中心频率严格直通。表内采用 65536 等分位置，顶端单独校正到 +200 音分；
 * 与正半程按 32767 等分的理想映射相比，包含插值误差后小于 0.02 音分。
 * 本模块不触发 note_on，持续按住一个键时只更新其频率即可。
 */
module pitch_bend_frequency_mapper
(
    input clk_sys,
    input rst_n,
    input [31:0] base_freq,
    input [15:0] bend_value,
    input in_valid,
    input out_ready,
    output [31:0] note_freq,
    output in_ready,
    output out_valid
);
    localparam S_WAIT_INPUT = 3'd0;
    localparam S_INTERPOLATE = 3'd1;
    localparam S_FORM_GAIN = 3'd2;
    localparam S_MULTIPLY = 3'd3;
    localparam S_SUM_PRODUCTS = 3'd4;
    localparam S_PUBLISH = 3'd5;
    localparam S_WAIT_OUTPUT = 3'd6;

    wire [2:0] stc;
    reg [2:0] stn;
    reg [31:0] base_freq_r;
    reg [23:0] gain_low_r;
    reg [15:0] gain_step_r;
    reg [10:0] fraction_r;
    reg top_endpoint_r;
    reg [26:0] interpolation_r;
    reg [23:0] gain_r;
    reg [39:0] product_low_r;
    reg [39:0] product_high_r;
    reg [55:0] product_r;
    reg [31:0] note_freq_r;
    reg out_valid_r;

    wire [5:0] table_index;
    wire [23:0] table_low;
    wire [23:0] table_high;
    wire [26:0] rounded_interpolation;
    wire [56:0] rounded_product;

    // round(2^((-200 + 12.5*index)/1200) * 2^22)，UQ2.22，无综合时实数运算。
    function [23:0] gain_lookup;
        input [5:0] index;
        begin
            case (index)
                6'd0: gain_lookup = 24'd3736700;
                6'd1: gain_lookup = 24'd3763778;
                6'd2: gain_lookup = 24'd3791052;
                6'd3: gain_lookup = 24'd3818523;
                6'd4: gain_lookup = 24'd3846194;
                6'd5: gain_lookup = 24'd3874065;
                6'd6: gain_lookup = 24'd3902138;
                6'd7: gain_lookup = 24'd3930414;
                6'd8: gain_lookup = 24'd3958896;
                6'd9: gain_lookup = 24'd3987584;
                6'd10: gain_lookup = 24'd4016479;
                6'd11: gain_lookup = 24'd4045584;
                6'd12: gain_lookup = 24'd4074900;
                6'd13: gain_lookup = 24'd4104429;
                6'd14: gain_lookup = 24'd4134171;
                6'd15: gain_lookup = 24'd4164129;
                6'd16: gain_lookup = 24'd4194304;
                6'd17: gain_lookup = 24'd4224698;
                6'd18: gain_lookup = 24'd4255312;
                6'd19: gain_lookup = 24'd4286147;
                6'd20: gain_lookup = 24'd4317206;
                6'd21: gain_lookup = 24'd4348491;
                6'd22: gain_lookup = 24'd4380002;
                6'd23: gain_lookup = 24'd4411741;
                6'd24: gain_lookup = 24'd4443710;
                6'd25: gain_lookup = 24'd4475911;
                6'd26: gain_lookup = 24'd4508346;
                6'd27: gain_lookup = 24'd4541015;
                6'd28: gain_lookup = 24'd4573921;
                6'd29: gain_lookup = 24'd4607065;
                6'd30: gain_lookup = 24'd4640450;
                6'd31: gain_lookup = 24'd4674077;
                6'd32: gain_lookup = 24'd4707947;
                default: gain_lookup = 24'd4194304;
            endcase
        end
    endfunction

    assign table_index = {1'b0, bend_value[15:11]};
    assign table_low = gain_lookup(table_index);
    assign table_high = gain_lookup(table_index + 6'd1);
    assign rounded_interpolation = interpolation_r + 27'd1024;
    assign rounded_product = {1'b0, product_r} + 57'd2097152;
    assign note_freq = note_freq_r;
    assign in_ready = rst_n && (stc == S_WAIT_INPUT);
    assign out_valid = out_valid_r;

    fsm #(
        .W(3),
        .INITIAL_STATE(S_WAIT_INPUT)
    ) fsm_u (
        .clk(clk_sys),
        .rst_n(rst_n),
        .stn(stn),
        .stc(stc)
    );

    always @(*)
    begin
        case (stc)
            S_WAIT_INPUT: stn = in_valid ? S_INTERPOLATE : S_WAIT_INPUT;
            S_INTERPOLATE: stn = S_FORM_GAIN;
            S_FORM_GAIN: stn = S_MULTIPLY;
            S_MULTIPLY: stn = S_SUM_PRODUCTS;
            S_SUM_PRODUCTS: stn = S_PUBLISH;
            S_PUBLISH: stn = S_WAIT_OUTPUT;
            S_WAIT_OUTPUT: stn = out_ready ? S_WAIT_INPUT : S_WAIT_OUTPUT;
            default: stn = S_WAIT_INPUT;
        endcase
    end

    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            base_freq_r <= 32'd0;
            gain_low_r <= 24'd4194304;
            gain_step_r <= 16'd0;
            fraction_r <= 11'd0;
            top_endpoint_r <= 1'b0;
            interpolation_r <= 27'd0;
            gain_r <= 24'd4194304;
            product_low_r <= 40'd0;
            product_high_r <= 40'd0;
            product_r <= 56'd0;
            note_freq_r <= 32'd0;
            out_valid_r <= 1'b0;
        end
        else
        begin
            case (stc)
                S_WAIT_INPUT:
                begin
                    if (in_valid)
                    begin
                        base_freq_r <= base_freq;
                        gain_low_r <= table_low;
                        gain_step_r <= table_high - table_low;
                        fraction_r <= bend_value[10:0];
                        top_endpoint_r <= (bend_value == 16'hFFFF);
                    end
                end

                S_INTERPOLATE:
                begin
                    interpolation_r <= gain_step_r * fraction_r;
                end

                S_FORM_GAIN:
                begin
                    gain_r <= top_endpoint_r ? 24'd4707947 :
                        gain_low_r + {8'd0, rounded_interpolation[26:11]};
                end

                S_MULTIPLY:
                begin
                    // 两个 16x24 乘积分别适配器件的 27x18 DSP，不丢失高频位。
                    product_low_r <= base_freq_r[15:0] * gain_r;
                    product_high_r <= base_freq_r[31:16] * gain_r;
                end

                S_SUM_PRODUCTS:
                begin
                    product_r <= {product_high_r, 16'd0} + {16'd0, product_low_r};
                end

                S_PUBLISH:
                begin
                    note_freq_r <= (|rounded_product[56:54]) ? 32'hFFFFFFFF :
                        rounded_product[53:22];
                    out_valid_r <= 1'b1;
                end

                S_WAIT_OUTPUT:
                begin
                    if (out_ready)
                    begin
                        out_valid_r <= 1'b0;
                    end
                end

                default:
                begin
                    out_valid_r <= 1'b0;
                end
            endcase
        end
    end
endmodule
