/**
 * 弯音比例模块 v2
 * v2 版本修改：插值乘法使用 LUT 实现，不使用 DSP，数值与握手规则不变。
 * 根据 ±200 音分计算倍率 r = 2^(cents/1200)，使用 257 个节点查表并线性插值。
 * 插值公式：r = r0 + round((r1-r0)*位置偏移/区间宽度)。
 * 查表使用 LUT 逻辑，不使用 ROM IP；除以区间宽度使用移位／加法，无运行时除法器。
 */

/**
 * bend_value: 16 位校准位置，0000/8000/ffff 对应 -200/0/+200 音分。
 * bend_ratio: 18 位 频率倍率 UQ1.17，中心精确为 1，升音时倍率大于 1。最终频率=基频 × 倍率。
 * clk_sys 上升沿 valid && ready 接收或交付；等待接收时保持结果与 valid。
 * 输入握手后第 4 拍结果有效，最早第 5 拍交付。
 * NOTE: 校准、中心死区及噪声滤波由驱动负责；本模块不附加时间平滑。
 */
module pitch_bend_controller (
    input clk_sys,
    input rst_n,
    input [15:0] bend_value,
    input in_valid,
    output in_ready,
    output [17:0] bend_ratio,
    output out_valid,
    input out_ready
) /* synthesis syn_romstyle = "logic" */;
    localparam STATE_WAIT_POSITION = 3'd0;
    localparam STATE_CALCULATE_INTERVAL = 3'd1;
    localparam STATE_MULTIPLY_OFFSET = 3'd2;
    localparam STATE_ROUND_OFFSET = 3'd3;
    localparam STATE_COMMIT_RATIO = 3'd4;
    localparam STATE_WAIT_RATIO_ACCEPT = 3'd5;
    wire [2:0] current_state;
    reg [2:0] next_state;
    reg [17:0] lower_ratio_r;
    reg [17:0] upper_ratio_r;
    reg [7:0] fraction_r;
    reg last_interval_r;
    reg [7:0] interval_delta_r;
    // 高云 SUG550：仅约束此乘法，不改变其他模块的 DSP 映射。
    reg [15:0] offset_product_r /* synthesis syn_dspstyle = "logic" */;
    reg [8:0] rounded_offset_r;
    reg [17:0] ratio_r;
    wire [16:0] last_numerator;
    wire [17:0] last_dividend;
    wire [17:0] interval_difference;

    function [17:0] lookup_ratio;
        input [8:0] index;
        begin
            case (index)
            // BEGIN_GENERATED_TABLE
                9'd0: lookup_ratio = 18'd116772;
                9'd1: lookup_ratio = 18'd116877;
                9'd2: lookup_ratio = 18'd116983;
                9'd3: lookup_ratio = 18'd117088;
                9'd4: lookup_ratio = 18'd117194;
                9'd5: lookup_ratio = 18'd117300;
                9'd6: lookup_ratio = 18'd117406;
                9'd7: lookup_ratio = 18'd117512;
                9'd8: lookup_ratio = 18'd117618;
                9'd9: lookup_ratio = 18'd117724;
                9'd10: lookup_ratio = 18'd117831;
                9'd11: lookup_ratio = 18'd117937;
                9'd12: lookup_ratio = 18'd118043;
                9'd13: lookup_ratio = 18'd118150;
                9'd14: lookup_ratio = 18'd118257;
                9'd15: lookup_ratio = 18'd118363;
                9'd16: lookup_ratio = 18'd118470;
                9'd17: lookup_ratio = 18'd118577;
                9'd18: lookup_ratio = 18'd118684;
                9'd19: lookup_ratio = 18'd118792;
                9'd20: lookup_ratio = 18'd118899;
                9'd21: lookup_ratio = 18'd119006;
                9'd22: lookup_ratio = 18'd119114;
                9'd23: lookup_ratio = 18'd119221;
                9'd24: lookup_ratio = 18'd119329;
                9'd25: lookup_ratio = 18'd119437;
                9'd26: lookup_ratio = 18'd119544;
                9'd27: lookup_ratio = 18'd119652;
                9'd28: lookup_ratio = 18'd119760;
                9'd29: lookup_ratio = 18'd119869;
                9'd30: lookup_ratio = 18'd119977;
                9'd31: lookup_ratio = 18'd120085;
                9'd32: lookup_ratio = 18'd120194;
                9'd33: lookup_ratio = 18'd120302;
                9'd34: lookup_ratio = 18'd120411;
                9'd35: lookup_ratio = 18'd120519;
                9'd36: lookup_ratio = 18'd120628;
                9'd37: lookup_ratio = 18'd120737;
                9'd38: lookup_ratio = 18'd120846;
                9'd39: lookup_ratio = 18'd120955;
                9'd40: lookup_ratio = 18'd121065;
                9'd41: lookup_ratio = 18'd121174;
                9'd42: lookup_ratio = 18'd121283;
                9'd43: lookup_ratio = 18'd121393;
                9'd44: lookup_ratio = 18'd121502;
                9'd45: lookup_ratio = 18'd121612;
                9'd46: lookup_ratio = 18'd121722;
                9'd47: lookup_ratio = 18'd121832;
                9'd48: lookup_ratio = 18'd121942;
                9'd49: lookup_ratio = 18'd122052;
                9'd50: lookup_ratio = 18'd122162;
                9'd51: lookup_ratio = 18'd122272;
                9'd52: lookup_ratio = 18'd122383;
                9'd53: lookup_ratio = 18'd122493;
                9'd54: lookup_ratio = 18'd122604;
                9'd55: lookup_ratio = 18'd122715;
                9'd56: lookup_ratio = 18'd122825;
                9'd57: lookup_ratio = 18'd122936;
                9'd58: lookup_ratio = 18'd123047;
                9'd59: lookup_ratio = 18'd123158;
                9'd60: lookup_ratio = 18'd123270;
                9'd61: lookup_ratio = 18'd123381;
                9'd62: lookup_ratio = 18'd123492;
                9'd63: lookup_ratio = 18'd123604;
                9'd64: lookup_ratio = 18'd123715;
                9'd65: lookup_ratio = 18'd123827;
                9'd66: lookup_ratio = 18'd123939;
                9'd67: lookup_ratio = 18'd124051;
                9'd68: lookup_ratio = 18'd124163;
                9'd69: lookup_ratio = 18'd124275;
                9'd70: lookup_ratio = 18'd124387;
                9'd71: lookup_ratio = 18'd124500;
                9'd72: lookup_ratio = 18'd124612;
                9'd73: lookup_ratio = 18'd124725;
                9'd74: lookup_ratio = 18'd124837;
                9'd75: lookup_ratio = 18'd124950;
                9'd76: lookup_ratio = 18'd125063;
                9'd77: lookup_ratio = 18'd125176;
                9'd78: lookup_ratio = 18'd125289;
                9'd79: lookup_ratio = 18'd125402;
                9'd80: lookup_ratio = 18'd125515;
                9'd81: lookup_ratio = 18'd125628;
                9'd82: lookup_ratio = 18'd125742;
                9'd83: lookup_ratio = 18'd125855;
                9'd84: lookup_ratio = 18'd125969;
                9'd85: lookup_ratio = 18'd126083;
                9'd86: lookup_ratio = 18'd126197;
                9'd87: lookup_ratio = 18'd126310;
                9'd88: lookup_ratio = 18'd126425;
                9'd89: lookup_ratio = 18'd126539;
                9'd90: lookup_ratio = 18'd126653;
                9'd91: lookup_ratio = 18'd126767;
                9'd92: lookup_ratio = 18'd126882;
                9'd93: lookup_ratio = 18'd126996;
                9'd94: lookup_ratio = 18'd127111;
                9'd95: lookup_ratio = 18'd127226;
                9'd96: lookup_ratio = 18'd127341;
                9'd97: lookup_ratio = 18'd127456;
                9'd98: lookup_ratio = 18'd127571;
                9'd99: lookup_ratio = 18'd127686;
                9'd100: lookup_ratio = 18'd127801;
                9'd101: lookup_ratio = 18'd127917;
                9'd102: lookup_ratio = 18'd128032;
                9'd103: lookup_ratio = 18'd128148;
                9'd104: lookup_ratio = 18'd128263;
                9'd105: lookup_ratio = 18'd128379;
                9'd106: lookup_ratio = 18'd128495;
                9'd107: lookup_ratio = 18'd128611;
                9'd108: lookup_ratio = 18'd128727;
                9'd109: lookup_ratio = 18'd128844;
                9'd110: lookup_ratio = 18'd128960;
                9'd111: lookup_ratio = 18'd129076;
                9'd112: lookup_ratio = 18'd129193;
                9'd113: lookup_ratio = 18'd129310;
                9'd114: lookup_ratio = 18'd129426;
                9'd115: lookup_ratio = 18'd129543;
                9'd116: lookup_ratio = 18'd129660;
                9'd117: lookup_ratio = 18'd129777;
                9'd118: lookup_ratio = 18'd129894;
                9'd119: lookup_ratio = 18'd130012;
                9'd120: lookup_ratio = 18'd130129;
                9'd121: lookup_ratio = 18'd130247;
                9'd122: lookup_ratio = 18'd130364;
                9'd123: lookup_ratio = 18'd130482;
                9'd124: lookup_ratio = 18'd130600;
                9'd125: lookup_ratio = 18'd130718;
                9'd126: lookup_ratio = 18'd130836;
                9'd127: lookup_ratio = 18'd130954;
                9'd128: lookup_ratio = 18'd131072;
                9'd129: lookup_ratio = 18'd131190;
                9'd130: lookup_ratio = 18'd131309;
                9'd131: lookup_ratio = 18'd131427;
                9'd132: lookup_ratio = 18'd131546;
                9'd133: lookup_ratio = 18'd131665;
                9'd134: lookup_ratio = 18'd131784;
                9'd135: lookup_ratio = 18'd131903;
                9'd136: lookup_ratio = 18'd132022;
                9'd137: lookup_ratio = 18'd132141;
                9'd138: lookup_ratio = 18'd132260;
                9'd139: lookup_ratio = 18'd132380;
                9'd140: lookup_ratio = 18'd132499;
                9'd141: lookup_ratio = 18'd132619;
                9'd142: lookup_ratio = 18'd132739;
                9'd143: lookup_ratio = 18'd132859;
                9'd144: lookup_ratio = 18'd132979;
                9'd145: lookup_ratio = 18'd133099;
                9'd146: lookup_ratio = 18'd133219;
                9'd147: lookup_ratio = 18'd133339;
                9'd148: lookup_ratio = 18'd133459;
                9'd149: lookup_ratio = 18'd133580;
                9'd150: lookup_ratio = 18'd133701;
                9'd151: lookup_ratio = 18'd133821;
                9'd152: lookup_ratio = 18'd133942;
                9'd153: lookup_ratio = 18'd134063;
                9'd154: lookup_ratio = 18'd134184;
                9'd155: lookup_ratio = 18'd134305;
                9'd156: lookup_ratio = 18'd134427;
                9'd157: lookup_ratio = 18'd134548;
                9'd158: lookup_ratio = 18'd134670;
                9'd159: lookup_ratio = 18'd134791;
                9'd160: lookup_ratio = 18'd134913;
                9'd161: lookup_ratio = 18'd135035;
                9'd162: lookup_ratio = 18'd135157;
                9'd163: lookup_ratio = 18'd135279;
                9'd164: lookup_ratio = 18'd135401;
                9'd165: lookup_ratio = 18'd135523;
                9'd166: lookup_ratio = 18'd135645;
                9'd167: lookup_ratio = 18'd135768;
                9'd168: lookup_ratio = 18'd135890;
                9'd169: lookup_ratio = 18'd136013;
                9'd170: lookup_ratio = 18'd136136;
                9'd171: lookup_ratio = 18'd136259;
                9'd172: lookup_ratio = 18'd136382;
                9'd173: lookup_ratio = 18'd136505;
                9'd174: lookup_ratio = 18'd136628;
                9'd175: lookup_ratio = 18'd136752;
                9'd176: lookup_ratio = 18'd136875;
                9'd177: lookup_ratio = 18'd136999;
                9'd178: lookup_ratio = 18'd137123;
                9'd179: lookup_ratio = 18'd137246;
                9'd180: lookup_ratio = 18'd137370;
                9'd181: lookup_ratio = 18'd137494;
                9'd182: lookup_ratio = 18'd137618;
                9'd183: lookup_ratio = 18'd137743;
                9'd184: lookup_ratio = 18'd137867;
                9'd185: lookup_ratio = 18'd137992;
                9'd186: lookup_ratio = 18'd138116;
                9'd187: lookup_ratio = 18'd138241;
                9'd188: lookup_ratio = 18'd138366;
                9'd189: lookup_ratio = 18'd138491;
                9'd190: lookup_ratio = 18'd138616;
                9'd191: lookup_ratio = 18'd138741;
                9'd192: lookup_ratio = 18'd138866;
                9'd193: lookup_ratio = 18'd138992;
                9'd194: lookup_ratio = 18'd139117;
                9'd195: lookup_ratio = 18'd139243;
                9'd196: lookup_ratio = 18'd139368;
                9'd197: lookup_ratio = 18'd139494;
                9'd198: lookup_ratio = 18'd139620;
                9'd199: lookup_ratio = 18'd139746;
                9'd200: lookup_ratio = 18'd139873;
                9'd201: lookup_ratio = 18'd139999;
                9'd202: lookup_ratio = 18'd140125;
                9'd203: lookup_ratio = 18'd140252;
                9'd204: lookup_ratio = 18'd140378;
                9'd205: lookup_ratio = 18'd140505;
                9'd206: lookup_ratio = 18'd140632;
                9'd207: lookup_ratio = 18'd140759;
                9'd208: lookup_ratio = 18'd140886;
                9'd209: lookup_ratio = 18'd141013;
                9'd210: lookup_ratio = 18'd141141;
                9'd211: lookup_ratio = 18'd141268;
                9'd212: lookup_ratio = 18'd141396;
                9'd213: lookup_ratio = 18'd141523;
                9'd214: lookup_ratio = 18'd141651;
                9'd215: lookup_ratio = 18'd141779;
                9'd216: lookup_ratio = 18'd141907;
                9'd217: lookup_ratio = 18'd142035;
                9'd218: lookup_ratio = 18'd142163;
                9'd219: lookup_ratio = 18'd142292;
                9'd220: lookup_ratio = 18'd142420;
                9'd221: lookup_ratio = 18'd142549;
                9'd222: lookup_ratio = 18'd142678;
                9'd223: lookup_ratio = 18'd142806;
                9'd224: lookup_ratio = 18'd142935;
                9'd225: lookup_ratio = 18'd143064;
                9'd226: lookup_ratio = 18'd143194;
                9'd227: lookup_ratio = 18'd143323;
                9'd228: lookup_ratio = 18'd143452;
                9'd229: lookup_ratio = 18'd143582;
                9'd230: lookup_ratio = 18'd143712;
                9'd231: lookup_ratio = 18'd143841;
                9'd232: lookup_ratio = 18'd143971;
                9'd233: lookup_ratio = 18'd144101;
                9'd234: lookup_ratio = 18'd144231;
                9'd235: lookup_ratio = 18'd144362;
                9'd236: lookup_ratio = 18'd144492;
                9'd237: lookup_ratio = 18'd144622;
                9'd238: lookup_ratio = 18'd144753;
                9'd239: lookup_ratio = 18'd144884;
                9'd240: lookup_ratio = 18'd145015;
                9'd241: lookup_ratio = 18'd145145;
                9'd242: lookup_ratio = 18'd145277;
                9'd243: lookup_ratio = 18'd145408;
                9'd244: lookup_ratio = 18'd145539;
                9'd245: lookup_ratio = 18'd145670;
                9'd246: lookup_ratio = 18'd145802;
                9'd247: lookup_ratio = 18'd145934;
                9'd248: lookup_ratio = 18'd146065;
                9'd249: lookup_ratio = 18'd146197;
                9'd250: lookup_ratio = 18'd146329;
                9'd251: lookup_ratio = 18'd146461;
                9'd252: lookup_ratio = 18'd146594;
                9'd253: lookup_ratio = 18'd146726;
                9'd254: lookup_ratio = 18'd146859;
                9'd255: lookup_ratio = 18'd146991;
                9'd256: lookup_ratio = 18'd147123;
            // END_GENERATED_TABLE
                default: lookup_ratio = 18'd131072;
            endcase
        end
    endfunction

    assign in_ready = rst_n && (current_state == STATE_WAIT_POSITION);
    assign out_valid = (current_state == STATE_WAIT_RATIO_ACCEPT);
    assign bend_ratio = ratio_r;
    assign interval_difference = upper_ratio_r - lower_ratio_r;
    // 最后一区间宽 255。对本表有限的非负分子，下面的移位加法等价于整除 255。
    // round(x/255) = floor((x+127)/255)，分子小于 65535；没有运行时除法器。
    assign last_numerator = {1'b0, offset_product_r} + 17'd127;
    assign last_dividend = {1'b0, last_numerator} + 18'd1 + {9'd0, last_numerator[16:8]};

    fsm #(.W(3), .INITIAL_STATE(STATE_WAIT_POSITION)) fsm_u (
        .clk(clk_sys), .rst_n(rst_n), .stn(next_state), .stc(current_state)
    );
    always @(*)
    begin
        next_state = current_state;
        case (current_state)
            STATE_WAIT_POSITION:
                if (in_valid) next_state = STATE_CALCULATE_INTERVAL;
            STATE_CALCULATE_INTERVAL: next_state = STATE_MULTIPLY_OFFSET;
            STATE_MULTIPLY_OFFSET: next_state = STATE_ROUND_OFFSET;
            STATE_ROUND_OFFSET: next_state = STATE_COMMIT_RATIO;
            STATE_COMMIT_RATIO: next_state = STATE_WAIT_RATIO_ACCEPT;
            STATE_WAIT_RATIO_ACCEPT:
                if (out_ready) next_state = STATE_WAIT_POSITION;
            default: next_state = STATE_WAIT_POSITION;
        endcase
    end
    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            lower_ratio_r <= 18'd131072;
            upper_ratio_r <= 18'd131072;
            fraction_r <= 8'd0;
            last_interval_r <= 1'b0;
            interval_delta_r <= 8'd0;
            offset_product_r <= 16'd0;
            rounded_offset_r <= 9'd0;
            ratio_r <= 18'd131072;
        end
        else
        begin
            case (current_state)
                STATE_WAIT_POSITION:
                    if (in_valid)
                    begin
                        lower_ratio_r <= lookup_ratio({1'b0, bend_value[15:8]});
                        upper_ratio_r <= lookup_ratio({1'b0, bend_value[15:8]} + 9'd1);
                        fraction_r <= bend_value[7:0];
                        last_interval_r <= (bend_value[15:8] == 8'hff);
                    end
                STATE_CALCULATE_INTERVAL:
                    // 节点最大差由生成器验证小于 256，显式取低八位避免隐式截断。
                    interval_delta_r <= interval_difference[7:0];
                STATE_MULTIPLY_OFFSET:
                    offset_product_r <= interval_delta_r * fraction_r;
                STATE_ROUND_OFFSET:
                    rounded_offset_r <= last_interval_r ? last_dividend[16:8] :
                        ({1'b0, offset_product_r[15:8]} + {8'd0, offset_product_r[7]});
                STATE_COMMIT_RATIO:
                    ratio_r <= lower_ratio_r + {9'd0, rounded_offset_r};
                default: ;
            endcase
        end
    end
endmodule
