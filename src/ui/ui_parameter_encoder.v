/**
 * 2026-10-31：两路增益统一UQ1.15，默认1.0（8000）；音色只保存balance，不保存master。
 * 把百分比、角度和毫秒换算成音频模块使用的参数编码。
 * 时序优化：输出 valid 由非复位状态产生，不将复位组合传播到下游整组 CE。
 * SMP_TICK_FREQ: 采样率，Hz，范围 1000～209715；毫秒换算采用四舍五入。
 * attack_ticks/decay_ticks/release_ticks: 20 位采样周期数，相对 S1 改了单位和位宽。
 * wavetable_interp: UQ1.15，0～8000 表示 0～100%；master/balance用UQ1.15全范围；干湿比和Sustain仍用UQ0.16。
 * advanced_parameters为8个16位音频编码；四路make_up同样直接锁存并同拍发布。
 * balance_volume为音色增益；master_volume为独立演奏总音量。
 * master_volume 与四个 *_mix: 总音量及混响、延迟、失真、合唱的干湿比。
 * 输入握手后分两拍转换；等待接收时保持整组结果，不混入新的设置。
 * NOTE: UQ0.16 的 100% 编码为 FFFF，略小于 1；Release=0 由音频端直接结束。
 * 本模块不计算实际音频，也不产生采样节拍。
 */
module ui_parameter_encoder
#(
    parameter SMP_TICK_FREQ = 48000  // 采样率，Hz，用于把毫秒换算成采样周期数
)(
    input clk_sys,
    input rst_n,
    input [3:0] wavetable_0 [0:0],
    input [3:0] wavetable_1 [0:0],
    input [6:0] interp_percent [0:0],
    input [8:0] phase_degrees [0:0],
    input [10:0] attack_ms [0:0],
    input [10:0] decay_ms [0:0],
    input [6:0] sustain_percent [0:0],
    input [12:0] release_ms [0:0],
    input [15:0] master_gain,
    input [127:0] advanced_parameters,  // 已编码的八项参数，随输入整组锁存
    input [63:0] make_up_gains,  // 四路 UQ1.15，已编码，随输入整组锁存
    input [15:0] balance_gain,  // 音色增益UQ1.15，独立于演奏总音量，同组握手
    input [6:0] reverb_mix_percent,
    input [6:0] delay_mix_percent,
    input [6:0] distortion_mix_percent,
    input [6:0] chorus_mix_percent,
    input in_valid,
    output in_ready,
    output [3:0] encoded_wavetable_0 [0:0],
    output [3:0] encoded_wavetable_1 [0:0],
    output [15:0] wavetable_interp [0:0],
    output [15:0] init_phase [0:0],
    output [19:0] attack_ticks [0:0],
    output [19:0] decay_ticks [0:0],
    output [15:0] sustain_level [0:0],
    output [19:0] release_ticks [0:0],
    output [15:0] master_volume,  // UQ1.15，0000..FFFF，默认8000；独立总增益，不随音色保存
    output [15:0] reverb_feedback,
    output [15:0] reverb_damping,
    output [15:0] delay_time,
    output [15:0] delay_feedback,
    output [15:0] distortion_gain,
    output [15:0] distortion_tone,
    output [15:0] chorus_rate,
    output [7:0] chorus_depth,
    output [15:0] balance_volume,  // UQ1.15；1.0为8000，范围[0,2)，随音色保存/加载
    output [15:0] reverb_mix,
    output [15:0] delay_mix,
    output [15:0] distortion_mix,
    output [15:0] chorus_mix,
    output [15:0] reverb_make_up,
    output [15:0] delay_make_up,
    output [15:0] distortion_make_up,
    output [15:0] chorus_make_up,
    output out_valid,
    input out_ready
) /* synthesis syn_romstyle = "logic" */;
    reg [127:0] advanced_captured_r, advanced_encoded_r;
    reg [63:0] make_up_captured_r, make_up_encoded_r;
    assign reverb_make_up = make_up_encoded_r[0 +: 16];
    assign delay_make_up = make_up_encoded_r[16 +: 16];
    assign distortion_make_up = make_up_encoded_r[32 +: 16];
    assign chorus_make_up = make_up_encoded_r[48 +: 16];
    assign reverb_feedback = advanced_encoded_r[0 +: 16];
    assign reverb_damping = advanced_encoded_r[16 +: 16];
    assign delay_time = advanced_encoded_r[32 +: 16];
    assign delay_feedback = advanced_encoded_r[48 +: 16];
    assign distortion_gain = advanced_encoded_r[64 +: 16];
    assign distortion_tone = advanced_encoded_r[80 +: 16];
    assign chorus_rate = advanced_encoded_r[96 +: 16];
    assign chorus_depth = advanced_encoded_r[112 +: 8];
    // 小型查表用逻辑实现，避免自动推断块 ROM 引入本工程的时钟脉宽违例。
    // 仅限定本模块，不改变正式 PLL、数值算法、两拍转换或 valid/ready 时序。
    localparam STATE_WAIT_PARAMETER_SNAPSHOT = 2'd0;
    localparam STATE_READ_TIME_PARTS = 2'd1;
    localparam STATE_CONVERT_SNAPSHOT = 2'd2;
    localparam STATE_WAIT_ENCODED_ACCEPT = 2'd3;
    wire [1:0] current_state;
    reg [1:0] next_state;
    reg [3:0] wavetable_0_captured;
    reg [3:0] wavetable_1_captured;
    reg [6:0] interp_percent_captured;
    reg [8:0] phase_degrees_captured;
    reg [10:0] attack_ms_captured;
    reg [10:0] decay_ms_captured;
    reg [6:0] sustain_percent_captured;
    reg [12:0] release_ms_captured;
    reg [15:0] master_gain_captured;
    reg [15:0] balance_gain_captured;
    reg [15:0] balance_volume_encoded_r;
    assign balance_volume = balance_volume_encoded_r;
    reg [6:0] reverb_mix_percent_captured;
    reg [6:0] delay_mix_percent_captured;
    reg [6:0] distortion_mix_percent_captured;
    reg [6:0] chorus_mix_percent_captured;
    reg [3:0] wavetable_0_encoded_r;
    assign encoded_wavetable_0[0] = wavetable_0_encoded_r;
    reg [3:0] wavetable_1_encoded_r;
    assign encoded_wavetable_1[0] = wavetable_1_encoded_r;
    reg [15:0] wavetable_interp_encoded_r;
    assign wavetable_interp[0] = wavetable_interp_encoded_r;
    reg [15:0] init_phase_encoded_r;
    assign init_phase[0] = init_phase_encoded_r;
    reg [19:0] attack_ticks_encoded_r;
    assign attack_ticks[0] = attack_ticks_encoded_r;
    reg [19:0] decay_ticks_encoded_r;
    assign decay_ticks[0] = decay_ticks_encoded_r;
    reg [15:0] sustain_level_encoded_r;
    assign sustain_level[0] = sustain_level_encoded_r;
    reg [19:0] release_ticks_encoded_r;
    assign release_ticks[0] = release_ticks_encoded_r;
    reg [15:0] master_volume_encoded_r;
    assign master_volume = master_volume_encoded_r;
    reg [15:0] reverb_mix_encoded_r;
    assign reverb_mix = reverb_mix_encoded_r;
    reg [15:0] delay_mix_encoded_r;
    assign delay_mix = delay_mix_encoded_r;
    reg [15:0] distortion_mix_encoded_r;
    assign distortion_mix = distortion_mix_encoded_r;
    reg [15:0] chorus_mix_encoded_r;
    assign chorus_mix = chorus_mix_encoded_r;

    // 参数单位 Hz；查表常量在综合展开时计算，无运行时除法。
    // 每个表项为 {32 位商, 10 位余数}，对 0～8191 ms 精确分解；输出超过 20 位时饱和，禁止回绕。
    localparam [63:0] TIME_SAMPLE_RATE_HZ = SMP_TICK_FREQ;
    reg [41:0] attack_high_part_r;
    reg [41:0] attack_low_part_r;
    // 余数之和加 500 最大为 2498，必须使用 12 位，不能截成 11 位。
    wire [11:0] attack_rounding_sum;
    wire [31:0] attack_sample_count;
    assign attack_sample_count = attack_high_part_r[41:10] + attack_low_part_r[41:10] +
        ((attack_rounding_sum >= 12'd2000) ? 32'd2 :
        ((attack_rounding_sum >= 12'd1000) ? 32'd1 : 32'd0));
    assign attack_rounding_sum = {2'b00,attack_high_part_r[9:0]} +
        {2'b00,attack_low_part_r[9:0]} + 12'd500;
    reg [41:0] decay_high_part_r;
    reg [41:0] decay_low_part_r;
    // 余数之和加 500 最大为 2498，必须使用 12 位，不能截成 11 位。
    wire [11:0] decay_rounding_sum;
    wire [31:0] decay_sample_count;
    assign decay_sample_count = decay_high_part_r[41:10] + decay_low_part_r[41:10] +
        ((decay_rounding_sum >= 12'd2000) ? 32'd2 :
        ((decay_rounding_sum >= 12'd1000) ? 32'd1 : 32'd0));
    assign decay_rounding_sum = {2'b00,decay_high_part_r[9:0]} +
        {2'b00,decay_low_part_r[9:0]} + 12'd500;
    reg [41:0] release_high_part_r;
    reg [41:0] release_low_part_r;
    // 余数之和加 500 最大为 2498，必须使用 12 位，不能截成 11 位。
    wire [11:0] release_rounding_sum;
    wire [31:0] release_sample_count;
    assign release_sample_count = release_high_part_r[41:10] + release_low_part_r[41:10] +
        ((release_rounding_sum >= 12'd2000) ? 32'd2 :
        ((release_rounding_sum >= 12'd1000) ? 32'd1 : 32'd0));
    assign release_rounding_sum = {2'b00,release_high_part_r[9:0]} +
        {2'b00,release_low_part_r[9:0]} + 12'd500;

    assign in_ready = rst_n && (current_state == STATE_WAIT_PARAMETER_SNAPSHOT);
    // 异步复位回到输入等待态，已保证 out_valid 无效。
    assign out_valid = (current_state == STATE_WAIT_ENCODED_ACCEPT);
    fsm #(
        .W(2), .INITIAL_STATE(STATE_WAIT_PARAMETER_SNAPSHOT)
    ) fsm_u (
        .clk(clk_sys), .rst_n(rst_n), .stn(next_state), .stc(current_state)
    );
    always @(*)
    begin
        next_state = current_state;
        case (current_state)
            STATE_WAIT_PARAMETER_SNAPSHOT:
                if (in_valid) next_state = STATE_READ_TIME_PARTS;
            STATE_READ_TIME_PARTS: next_state = STATE_CONVERT_SNAPSHOT;
            STATE_CONVERT_SNAPSHOT: next_state = STATE_WAIT_ENCODED_ACCEPT;
            STATE_WAIT_ENCODED_ACCEPT:
                if (out_ready) next_state = STATE_WAIT_PARAMETER_SNAPSHOT;
            default: next_state = STATE_WAIT_PARAMETER_SNAPSHOT;
        endcase
    end

    // 对有限合法输入域进行精确组合查表。
    function [15:0] encode_percent;
        input [6:0] percent;
        begin
            case (percent)
                7'd0: encode_percent = 16'd0;
                7'd1: encode_percent = 16'd655;
                7'd2: encode_percent = 16'd1311;
                7'd3: encode_percent = 16'd1966;
                7'd4: encode_percent = 16'd2621;
                7'd5: encode_percent = 16'd3277;
                7'd6: encode_percent = 16'd3932;
                7'd7: encode_percent = 16'd4588;
                7'd8: encode_percent = 16'd5243;
                7'd9: encode_percent = 16'd5898;
                7'd10: encode_percent = 16'd6554;
                7'd11: encode_percent = 16'd7209;
                7'd12: encode_percent = 16'd7864;
                7'd13: encode_percent = 16'd8520;
                7'd14: encode_percent = 16'd9175;
                7'd15: encode_percent = 16'd9830;
                7'd16: encode_percent = 16'd10486;
                7'd17: encode_percent = 16'd11141;
                7'd18: encode_percent = 16'd11796;
                7'd19: encode_percent = 16'd12452;
                7'd20: encode_percent = 16'd13107;
                7'd21: encode_percent = 16'd13763;
                7'd22: encode_percent = 16'd14418;
                7'd23: encode_percent = 16'd15073;
                7'd24: encode_percent = 16'd15729;
                7'd25: encode_percent = 16'd16384;
                7'd26: encode_percent = 16'd17039;
                7'd27: encode_percent = 16'd17695;
                7'd28: encode_percent = 16'd18350;
                7'd29: encode_percent = 16'd19005;
                7'd30: encode_percent = 16'd19661;
                7'd31: encode_percent = 16'd20316;
                7'd32: encode_percent = 16'd20972;
                7'd33: encode_percent = 16'd21627;
                7'd34: encode_percent = 16'd22282;
                7'd35: encode_percent = 16'd22938;
                7'd36: encode_percent = 16'd23593;
                7'd37: encode_percent = 16'd24248;
                7'd38: encode_percent = 16'd24904;
                7'd39: encode_percent = 16'd25559;
                7'd40: encode_percent = 16'd26214;
                7'd41: encode_percent = 16'd26870;
                7'd42: encode_percent = 16'd27525;
                7'd43: encode_percent = 16'd28180;
                7'd44: encode_percent = 16'd28836;
                7'd45: encode_percent = 16'd29491;
                7'd46: encode_percent = 16'd30147;
                7'd47: encode_percent = 16'd30802;
                7'd48: encode_percent = 16'd31457;
                7'd49: encode_percent = 16'd32113;
                7'd50: encode_percent = 16'd32768;
                7'd51: encode_percent = 16'd33423;
                7'd52: encode_percent = 16'd34079;
                7'd53: encode_percent = 16'd34734;
                7'd54: encode_percent = 16'd35389;
                7'd55: encode_percent = 16'd36045;
                7'd56: encode_percent = 16'd36700;
                7'd57: encode_percent = 16'd37356;
                7'd58: encode_percent = 16'd38011;
                7'd59: encode_percent = 16'd38666;
                7'd60: encode_percent = 16'd39322;
                7'd61: encode_percent = 16'd39977;
                7'd62: encode_percent = 16'd40632;
                7'd63: encode_percent = 16'd41288;
                7'd64: encode_percent = 16'd41943;
                7'd65: encode_percent = 16'd42598;
                7'd66: encode_percent = 16'd43254;
                7'd67: encode_percent = 16'd43909;
                7'd68: encode_percent = 16'd44564;
                7'd69: encode_percent = 16'd45220;
                7'd70: encode_percent = 16'd45875;
                7'd71: encode_percent = 16'd46531;
                7'd72: encode_percent = 16'd47186;
                7'd73: encode_percent = 16'd47841;
                7'd74: encode_percent = 16'd48497;
                7'd75: encode_percent = 16'd49152;
                7'd76: encode_percent = 16'd49807;
                7'd77: encode_percent = 16'd50463;
                7'd78: encode_percent = 16'd51118;
                7'd79: encode_percent = 16'd51773;
                7'd80: encode_percent = 16'd52429;
                7'd81: encode_percent = 16'd53084;
                7'd82: encode_percent = 16'd53740;
                7'd83: encode_percent = 16'd54395;
                7'd84: encode_percent = 16'd55050;
                7'd85: encode_percent = 16'd55706;
                7'd86: encode_percent = 16'd56361;
                7'd87: encode_percent = 16'd57016;
                7'd88: encode_percent = 16'd57672;
                7'd89: encode_percent = 16'd58327;
                7'd90: encode_percent = 16'd58982;
                7'd91: encode_percent = 16'd59638;
                7'd92: encode_percent = 16'd60293;
                7'd93: encode_percent = 16'd60948;
                7'd94: encode_percent = 16'd61604;
                7'd95: encode_percent = 16'd62259;
                7'd96: encode_percent = 16'd62915;
                7'd97: encode_percent = 16'd63570;
                7'd98: encode_percent = 16'd64225;
                7'd99: encode_percent = 16'd64881;
                7'd100: encode_percent = 16'd65535;
                default: encode_percent = 16'd65535;
            endcase
        end
    endfunction
    function [15:0] encode_interp;
        input [6:0] percent;
        begin
            case (percent)
                7'd0: encode_interp = 16'd0;
                7'd1: encode_interp = 16'd328;
                7'd2: encode_interp = 16'd655;
                7'd3: encode_interp = 16'd983;
                7'd4: encode_interp = 16'd1311;
                7'd5: encode_interp = 16'd1638;
                7'd6: encode_interp = 16'd1966;
                7'd7: encode_interp = 16'd2294;
                7'd8: encode_interp = 16'd2621;
                7'd9: encode_interp = 16'd2949;
                7'd10: encode_interp = 16'd3277;
                7'd11: encode_interp = 16'd3604;
                7'd12: encode_interp = 16'd3932;
                7'd13: encode_interp = 16'd4260;
                7'd14: encode_interp = 16'd4588;
                7'd15: encode_interp = 16'd4915;
                7'd16: encode_interp = 16'd5243;
                7'd17: encode_interp = 16'd5571;
                7'd18: encode_interp = 16'd5898;
                7'd19: encode_interp = 16'd6226;
                7'd20: encode_interp = 16'd6554;
                7'd21: encode_interp = 16'd6881;
                7'd22: encode_interp = 16'd7209;
                7'd23: encode_interp = 16'd7537;
                7'd24: encode_interp = 16'd7864;
                7'd25: encode_interp = 16'd8192;
                7'd26: encode_interp = 16'd8520;
                7'd27: encode_interp = 16'd8847;
                7'd28: encode_interp = 16'd9175;
                7'd29: encode_interp = 16'd9503;
                7'd30: encode_interp = 16'd9830;
                7'd31: encode_interp = 16'd10158;
                7'd32: encode_interp = 16'd10486;
                7'd33: encode_interp = 16'd10813;
                7'd34: encode_interp = 16'd11141;
                7'd35: encode_interp = 16'd11469;
                7'd36: encode_interp = 16'd11796;
                7'd37: encode_interp = 16'd12124;
                7'd38: encode_interp = 16'd12452;
                7'd39: encode_interp = 16'd12780;
                7'd40: encode_interp = 16'd13107;
                7'd41: encode_interp = 16'd13435;
                7'd42: encode_interp = 16'd13763;
                7'd43: encode_interp = 16'd14090;
                7'd44: encode_interp = 16'd14418;
                7'd45: encode_interp = 16'd14746;
                7'd46: encode_interp = 16'd15073;
                7'd47: encode_interp = 16'd15401;
                7'd48: encode_interp = 16'd15729;
                7'd49: encode_interp = 16'd16056;
                7'd50: encode_interp = 16'd16384;
                7'd51: encode_interp = 16'd16712;
                7'd52: encode_interp = 16'd17039;
                7'd53: encode_interp = 16'd17367;
                7'd54: encode_interp = 16'd17695;
                7'd55: encode_interp = 16'd18022;
                7'd56: encode_interp = 16'd18350;
                7'd57: encode_interp = 16'd18678;
                7'd58: encode_interp = 16'd19005;
                7'd59: encode_interp = 16'd19333;
                7'd60: encode_interp = 16'd19661;
                7'd61: encode_interp = 16'd19988;
                7'd62: encode_interp = 16'd20316;
                7'd63: encode_interp = 16'd20644;
                7'd64: encode_interp = 16'd20972;
                7'd65: encode_interp = 16'd21299;
                7'd66: encode_interp = 16'd21627;
                7'd67: encode_interp = 16'd21955;
                7'd68: encode_interp = 16'd22282;
                7'd69: encode_interp = 16'd22610;
                7'd70: encode_interp = 16'd22938;
                7'd71: encode_interp = 16'd23265;
                7'd72: encode_interp = 16'd23593;
                7'd73: encode_interp = 16'd23921;
                7'd74: encode_interp = 16'd24248;
                7'd75: encode_interp = 16'd24576;
                7'd76: encode_interp = 16'd24904;
                7'd77: encode_interp = 16'd25231;
                7'd78: encode_interp = 16'd25559;
                7'd79: encode_interp = 16'd25887;
                7'd80: encode_interp = 16'd26214;
                7'd81: encode_interp = 16'd26542;
                7'd82: encode_interp = 16'd26870;
                7'd83: encode_interp = 16'd27197;
                7'd84: encode_interp = 16'd27525;
                7'd85: encode_interp = 16'd27853;
                7'd86: encode_interp = 16'd28180;
                7'd87: encode_interp = 16'd28508;
                7'd88: encode_interp = 16'd28836;
                7'd89: encode_interp = 16'd29164;
                7'd90: encode_interp = 16'd29491;
                7'd91: encode_interp = 16'd29819;
                7'd92: encode_interp = 16'd30147;
                7'd93: encode_interp = 16'd30474;
                7'd94: encode_interp = 16'd30802;
                7'd95: encode_interp = 16'd31130;
                7'd96: encode_interp = 16'd31457;
                7'd97: encode_interp = 16'd31785;
                7'd98: encode_interp = 16'd32113;
                7'd99: encode_interp = 16'd32440;
                7'd100: encode_interp = 16'd32768;
                default: encode_interp = 16'd0;
            endcase
        end
    endfunction
    function [15:0] encode_phase;
        input [8:0] degrees;
        begin
            case (degrees)
                9'd0: encode_phase = 16'd0;
                9'd1: encode_phase = 16'd182;
                9'd2: encode_phase = 16'd364;
                9'd3: encode_phase = 16'd546;
                9'd4: encode_phase = 16'd728;
                9'd5: encode_phase = 16'd910;
                9'd6: encode_phase = 16'd1092;
                9'd7: encode_phase = 16'd1274;
                9'd8: encode_phase = 16'd1456;
                9'd9: encode_phase = 16'd1638;
                9'd10: encode_phase = 16'd1820;
                9'd11: encode_phase = 16'd2002;
                9'd12: encode_phase = 16'd2185;
                9'd13: encode_phase = 16'd2367;
                9'd14: encode_phase = 16'd2549;
                9'd15: encode_phase = 16'd2731;
                9'd16: encode_phase = 16'd2913;
                9'd17: encode_phase = 16'd3095;
                9'd18: encode_phase = 16'd3277;
                9'd19: encode_phase = 16'd3459;
                9'd20: encode_phase = 16'd3641;
                9'd21: encode_phase = 16'd3823;
                9'd22: encode_phase = 16'd4005;
                9'd23: encode_phase = 16'd4187;
                9'd24: encode_phase = 16'd4369;
                9'd25: encode_phase = 16'd4551;
                9'd26: encode_phase = 16'd4733;
                9'd27: encode_phase = 16'd4915;
                9'd28: encode_phase = 16'd5097;
                9'd29: encode_phase = 16'd5279;
                9'd30: encode_phase = 16'd5461;
                9'd31: encode_phase = 16'd5643;
                9'd32: encode_phase = 16'd5825;
                9'd33: encode_phase = 16'd6007;
                9'd34: encode_phase = 16'd6190;
                9'd35: encode_phase = 16'd6372;
                9'd36: encode_phase = 16'd6554;
                9'd37: encode_phase = 16'd6736;
                9'd38: encode_phase = 16'd6918;
                9'd39: encode_phase = 16'd7100;
                9'd40: encode_phase = 16'd7282;
                9'd41: encode_phase = 16'd7464;
                9'd42: encode_phase = 16'd7646;
                9'd43: encode_phase = 16'd7828;
                9'd44: encode_phase = 16'd8010;
                9'd45: encode_phase = 16'd8192;
                9'd46: encode_phase = 16'd8374;
                9'd47: encode_phase = 16'd8556;
                9'd48: encode_phase = 16'd8738;
                9'd49: encode_phase = 16'd8920;
                9'd50: encode_phase = 16'd9102;
                9'd51: encode_phase = 16'd9284;
                9'd52: encode_phase = 16'd9466;
                9'd53: encode_phase = 16'd9648;
                9'd54: encode_phase = 16'd9830;
                9'd55: encode_phase = 16'd10012;
                9'd56: encode_phase = 16'd10194;
                9'd57: encode_phase = 16'd10377;
                9'd58: encode_phase = 16'd10559;
                9'd59: encode_phase = 16'd10741;
                9'd60: encode_phase = 16'd10923;
                9'd61: encode_phase = 16'd11105;
                9'd62: encode_phase = 16'd11287;
                9'd63: encode_phase = 16'd11469;
                9'd64: encode_phase = 16'd11651;
                9'd65: encode_phase = 16'd11833;
                9'd66: encode_phase = 16'd12015;
                9'd67: encode_phase = 16'd12197;
                9'd68: encode_phase = 16'd12379;
                9'd69: encode_phase = 16'd12561;
                9'd70: encode_phase = 16'd12743;
                9'd71: encode_phase = 16'd12925;
                9'd72: encode_phase = 16'd13107;
                9'd73: encode_phase = 16'd13289;
                9'd74: encode_phase = 16'd13471;
                9'd75: encode_phase = 16'd13653;
                9'd76: encode_phase = 16'd13835;
                9'd77: encode_phase = 16'd14017;
                9'd78: encode_phase = 16'd14199;
                9'd79: encode_phase = 16'd14382;
                9'd80: encode_phase = 16'd14564;
                9'd81: encode_phase = 16'd14746;
                9'd82: encode_phase = 16'd14928;
                9'd83: encode_phase = 16'd15110;
                9'd84: encode_phase = 16'd15292;
                9'd85: encode_phase = 16'd15474;
                9'd86: encode_phase = 16'd15656;
                9'd87: encode_phase = 16'd15838;
                9'd88: encode_phase = 16'd16020;
                9'd89: encode_phase = 16'd16202;
                9'd90: encode_phase = 16'd16384;
                9'd91: encode_phase = 16'd16566;
                9'd92: encode_phase = 16'd16748;
                9'd93: encode_phase = 16'd16930;
                9'd94: encode_phase = 16'd17112;
                9'd95: encode_phase = 16'd17294;
                9'd96: encode_phase = 16'd17476;
                9'd97: encode_phase = 16'd17658;
                9'd98: encode_phase = 16'd17840;
                9'd99: encode_phase = 16'd18022;
                9'd100: encode_phase = 16'd18204;
                9'd101: encode_phase = 16'd18386;
                9'd102: encode_phase = 16'd18569;
                9'd103: encode_phase = 16'd18751;
                9'd104: encode_phase = 16'd18933;
                9'd105: encode_phase = 16'd19115;
                9'd106: encode_phase = 16'd19297;
                9'd107: encode_phase = 16'd19479;
                9'd108: encode_phase = 16'd19661;
                9'd109: encode_phase = 16'd19843;
                9'd110: encode_phase = 16'd20025;
                9'd111: encode_phase = 16'd20207;
                9'd112: encode_phase = 16'd20389;
                9'd113: encode_phase = 16'd20571;
                9'd114: encode_phase = 16'd20753;
                9'd115: encode_phase = 16'd20935;
                9'd116: encode_phase = 16'd21117;
                9'd117: encode_phase = 16'd21299;
                9'd118: encode_phase = 16'd21481;
                9'd119: encode_phase = 16'd21663;
                9'd120: encode_phase = 16'd21845;
                9'd121: encode_phase = 16'd22027;
                9'd122: encode_phase = 16'd22209;
                9'd123: encode_phase = 16'd22391;
                9'd124: encode_phase = 16'd22574;
                9'd125: encode_phase = 16'd22756;
                9'd126: encode_phase = 16'd22938;
                9'd127: encode_phase = 16'd23120;
                9'd128: encode_phase = 16'd23302;
                9'd129: encode_phase = 16'd23484;
                9'd130: encode_phase = 16'd23666;
                9'd131: encode_phase = 16'd23848;
                9'd132: encode_phase = 16'd24030;
                9'd133: encode_phase = 16'd24212;
                9'd134: encode_phase = 16'd24394;
                9'd135: encode_phase = 16'd24576;
                9'd136: encode_phase = 16'd24758;
                9'd137: encode_phase = 16'd24940;
                9'd138: encode_phase = 16'd25122;
                9'd139: encode_phase = 16'd25304;
                9'd140: encode_phase = 16'd25486;
                9'd141: encode_phase = 16'd25668;
                9'd142: encode_phase = 16'd25850;
                9'd143: encode_phase = 16'd26032;
                9'd144: encode_phase = 16'd26214;
                9'd145: encode_phase = 16'd26396;
                9'd146: encode_phase = 16'd26578;
                9'd147: encode_phase = 16'd26761;
                9'd148: encode_phase = 16'd26943;
                9'd149: encode_phase = 16'd27125;
                9'd150: encode_phase = 16'd27307;
                9'd151: encode_phase = 16'd27489;
                9'd152: encode_phase = 16'd27671;
                9'd153: encode_phase = 16'd27853;
                9'd154: encode_phase = 16'd28035;
                9'd155: encode_phase = 16'd28217;
                9'd156: encode_phase = 16'd28399;
                9'd157: encode_phase = 16'd28581;
                9'd158: encode_phase = 16'd28763;
                9'd159: encode_phase = 16'd28945;
                9'd160: encode_phase = 16'd29127;
                9'd161: encode_phase = 16'd29309;
                9'd162: encode_phase = 16'd29491;
                9'd163: encode_phase = 16'd29673;
                9'd164: encode_phase = 16'd29855;
                9'd165: encode_phase = 16'd30037;
                9'd166: encode_phase = 16'd30219;
                9'd167: encode_phase = 16'd30401;
                9'd168: encode_phase = 16'd30583;
                9'd169: encode_phase = 16'd30766;
                9'd170: encode_phase = 16'd30948;
                9'd171: encode_phase = 16'd31130;
                9'd172: encode_phase = 16'd31312;
                9'd173: encode_phase = 16'd31494;
                9'd174: encode_phase = 16'd31676;
                9'd175: encode_phase = 16'd31858;
                9'd176: encode_phase = 16'd32040;
                9'd177: encode_phase = 16'd32222;
                9'd178: encode_phase = 16'd32404;
                9'd179: encode_phase = 16'd32586;
                9'd180: encode_phase = 16'd32768;
                9'd181: encode_phase = 16'd32950;
                9'd182: encode_phase = 16'd33132;
                9'd183: encode_phase = 16'd33314;
                9'd184: encode_phase = 16'd33496;
                9'd185: encode_phase = 16'd33678;
                9'd186: encode_phase = 16'd33860;
                9'd187: encode_phase = 16'd34042;
                9'd188: encode_phase = 16'd34224;
                9'd189: encode_phase = 16'd34406;
                9'd190: encode_phase = 16'd34588;
                9'd191: encode_phase = 16'd34770;
                9'd192: encode_phase = 16'd34953;
                9'd193: encode_phase = 16'd35135;
                9'd194: encode_phase = 16'd35317;
                9'd195: encode_phase = 16'd35499;
                9'd196: encode_phase = 16'd35681;
                9'd197: encode_phase = 16'd35863;
                9'd198: encode_phase = 16'd36045;
                9'd199: encode_phase = 16'd36227;
                9'd200: encode_phase = 16'd36409;
                9'd201: encode_phase = 16'd36591;
                9'd202: encode_phase = 16'd36773;
                9'd203: encode_phase = 16'd36955;
                9'd204: encode_phase = 16'd37137;
                9'd205: encode_phase = 16'd37319;
                9'd206: encode_phase = 16'd37501;
                9'd207: encode_phase = 16'd37683;
                9'd208: encode_phase = 16'd37865;
                9'd209: encode_phase = 16'd38047;
                9'd210: encode_phase = 16'd38229;
                9'd211: encode_phase = 16'd38411;
                9'd212: encode_phase = 16'd38593;
                9'd213: encode_phase = 16'd38775;
                9'd214: encode_phase = 16'd38958;
                9'd215: encode_phase = 16'd39140;
                9'd216: encode_phase = 16'd39322;
                9'd217: encode_phase = 16'd39504;
                9'd218: encode_phase = 16'd39686;
                9'd219: encode_phase = 16'd39868;
                9'd220: encode_phase = 16'd40050;
                9'd221: encode_phase = 16'd40232;
                9'd222: encode_phase = 16'd40414;
                9'd223: encode_phase = 16'd40596;
                9'd224: encode_phase = 16'd40778;
                9'd225: encode_phase = 16'd40960;
                9'd226: encode_phase = 16'd41142;
                9'd227: encode_phase = 16'd41324;
                9'd228: encode_phase = 16'd41506;
                9'd229: encode_phase = 16'd41688;
                9'd230: encode_phase = 16'd41870;
                9'd231: encode_phase = 16'd42052;
                9'd232: encode_phase = 16'd42234;
                9'd233: encode_phase = 16'd42416;
                9'd234: encode_phase = 16'd42598;
                9'd235: encode_phase = 16'd42780;
                9'd236: encode_phase = 16'd42962;
                9'd237: encode_phase = 16'd43145;
                9'd238: encode_phase = 16'd43327;
                9'd239: encode_phase = 16'd43509;
                9'd240: encode_phase = 16'd43691;
                9'd241: encode_phase = 16'd43873;
                9'd242: encode_phase = 16'd44055;
                9'd243: encode_phase = 16'd44237;
                9'd244: encode_phase = 16'd44419;
                9'd245: encode_phase = 16'd44601;
                9'd246: encode_phase = 16'd44783;
                9'd247: encode_phase = 16'd44965;
                9'd248: encode_phase = 16'd45147;
                9'd249: encode_phase = 16'd45329;
                9'd250: encode_phase = 16'd45511;
                9'd251: encode_phase = 16'd45693;
                9'd252: encode_phase = 16'd45875;
                9'd253: encode_phase = 16'd46057;
                9'd254: encode_phase = 16'd46239;
                9'd255: encode_phase = 16'd46421;
                9'd256: encode_phase = 16'd46603;
                9'd257: encode_phase = 16'd46785;
                9'd258: encode_phase = 16'd46967;
                9'd259: encode_phase = 16'd47150;
                9'd260: encode_phase = 16'd47332;
                9'd261: encode_phase = 16'd47514;
                9'd262: encode_phase = 16'd47696;
                9'd263: encode_phase = 16'd47878;
                9'd264: encode_phase = 16'd48060;
                9'd265: encode_phase = 16'd48242;
                9'd266: encode_phase = 16'd48424;
                9'd267: encode_phase = 16'd48606;
                9'd268: encode_phase = 16'd48788;
                9'd269: encode_phase = 16'd48970;
                9'd270: encode_phase = 16'd49152;
                9'd271: encode_phase = 16'd49334;
                9'd272: encode_phase = 16'd49516;
                9'd273: encode_phase = 16'd49698;
                9'd274: encode_phase = 16'd49880;
                9'd275: encode_phase = 16'd50062;
                9'd276: encode_phase = 16'd50244;
                9'd277: encode_phase = 16'd50426;
                9'd278: encode_phase = 16'd50608;
                9'd279: encode_phase = 16'd50790;
                9'd280: encode_phase = 16'd50972;
                9'd281: encode_phase = 16'd51154;
                9'd282: encode_phase = 16'd51337;
                9'd283: encode_phase = 16'd51519;
                9'd284: encode_phase = 16'd51701;
                9'd285: encode_phase = 16'd51883;
                9'd286: encode_phase = 16'd52065;
                9'd287: encode_phase = 16'd52247;
                9'd288: encode_phase = 16'd52429;
                9'd289: encode_phase = 16'd52611;
                9'd290: encode_phase = 16'd52793;
                9'd291: encode_phase = 16'd52975;
                9'd292: encode_phase = 16'd53157;
                9'd293: encode_phase = 16'd53339;
                9'd294: encode_phase = 16'd53521;
                9'd295: encode_phase = 16'd53703;
                9'd296: encode_phase = 16'd53885;
                9'd297: encode_phase = 16'd54067;
                9'd298: encode_phase = 16'd54249;
                9'd299: encode_phase = 16'd54431;
                9'd300: encode_phase = 16'd54613;
                9'd301: encode_phase = 16'd54795;
                9'd302: encode_phase = 16'd54977;
                9'd303: encode_phase = 16'd55159;
                9'd304: encode_phase = 16'd55342;
                9'd305: encode_phase = 16'd55524;
                9'd306: encode_phase = 16'd55706;
                9'd307: encode_phase = 16'd55888;
                9'd308: encode_phase = 16'd56070;
                9'd309: encode_phase = 16'd56252;
                9'd310: encode_phase = 16'd56434;
                9'd311: encode_phase = 16'd56616;
                9'd312: encode_phase = 16'd56798;
                9'd313: encode_phase = 16'd56980;
                9'd314: encode_phase = 16'd57162;
                9'd315: encode_phase = 16'd57344;
                9'd316: encode_phase = 16'd57526;
                9'd317: encode_phase = 16'd57708;
                9'd318: encode_phase = 16'd57890;
                9'd319: encode_phase = 16'd58072;
                9'd320: encode_phase = 16'd58254;
                9'd321: encode_phase = 16'd58436;
                9'd322: encode_phase = 16'd58618;
                9'd323: encode_phase = 16'd58800;
                9'd324: encode_phase = 16'd58982;
                9'd325: encode_phase = 16'd59164;
                9'd326: encode_phase = 16'd59346;
                9'd327: encode_phase = 16'd59529;
                9'd328: encode_phase = 16'd59711;
                9'd329: encode_phase = 16'd59893;
                9'd330: encode_phase = 16'd60075;
                9'd331: encode_phase = 16'd60257;
                9'd332: encode_phase = 16'd60439;
                9'd333: encode_phase = 16'd60621;
                9'd334: encode_phase = 16'd60803;
                9'd335: encode_phase = 16'd60985;
                9'd336: encode_phase = 16'd61167;
                9'd337: encode_phase = 16'd61349;
                9'd338: encode_phase = 16'd61531;
                9'd339: encode_phase = 16'd61713;
                9'd340: encode_phase = 16'd61895;
                9'd341: encode_phase = 16'd62077;
                9'd342: encode_phase = 16'd62259;
                9'd343: encode_phase = 16'd62441;
                9'd344: encode_phase = 16'd62623;
                9'd345: encode_phase = 16'd62805;
                9'd346: encode_phase = 16'd62987;
                9'd347: encode_phase = 16'd63169;
                9'd348: encode_phase = 16'd63351;
                9'd349: encode_phase = 16'd63534;
                9'd350: encode_phase = 16'd63716;
                9'd351: encode_phase = 16'd63898;
                9'd352: encode_phase = 16'd64080;
                9'd353: encode_phase = 16'd64262;
                9'd354: encode_phase = 16'd64444;
                9'd355: encode_phase = 16'd64626;
                9'd356: encode_phase = 16'd64808;
                9'd357: encode_phase = 16'd64990;
                9'd358: encode_phase = 16'd65172;
                9'd359: encode_phase = 16'd65354;
                default: encode_phase = 16'd0;
            endcase
        end
    endfunction
    function [41:0] time_high_parts;
        input [7:0] index;
        begin
            case (index)
                8'd0: time_high_parts = ((((64'd0 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd0 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd1: time_high_parts = ((((64'd32 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd32 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd2: time_high_parts = ((((64'd64 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd64 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd3: time_high_parts = ((((64'd96 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd96 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd4: time_high_parts = ((((64'd128 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd128 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd5: time_high_parts = ((((64'd160 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd160 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd6: time_high_parts = ((((64'd192 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd192 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd7: time_high_parts = ((((64'd224 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd224 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd8: time_high_parts = ((((64'd256 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd256 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd9: time_high_parts = ((((64'd288 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd288 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd10: time_high_parts = ((((64'd320 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd320 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd11: time_high_parts = ((((64'd352 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd352 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd12: time_high_parts = ((((64'd384 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd384 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd13: time_high_parts = ((((64'd416 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd416 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd14: time_high_parts = ((((64'd448 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd448 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd15: time_high_parts = ((((64'd480 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd480 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd16: time_high_parts = ((((64'd512 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd512 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd17: time_high_parts = ((((64'd544 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd544 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd18: time_high_parts = ((((64'd576 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd576 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd19: time_high_parts = ((((64'd608 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd608 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd20: time_high_parts = ((((64'd640 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd640 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd21: time_high_parts = ((((64'd672 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd672 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd22: time_high_parts = ((((64'd704 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd704 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd23: time_high_parts = ((((64'd736 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd736 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd24: time_high_parts = ((((64'd768 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd768 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd25: time_high_parts = ((((64'd800 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd800 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd26: time_high_parts = ((((64'd832 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd832 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd27: time_high_parts = ((((64'd864 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd864 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd28: time_high_parts = ((((64'd896 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd896 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd29: time_high_parts = ((((64'd928 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd928 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd30: time_high_parts = ((((64'd960 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd960 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd31: time_high_parts = ((((64'd992 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd992 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd32: time_high_parts = ((((64'd1024 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd1024 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd33: time_high_parts = ((((64'd1056 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd1056 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd34: time_high_parts = ((((64'd1088 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd1088 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd35: time_high_parts = ((((64'd1120 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd1120 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd36: time_high_parts = ((((64'd1152 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd1152 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd37: time_high_parts = ((((64'd1184 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd1184 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd38: time_high_parts = ((((64'd1216 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd1216 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd39: time_high_parts = ((((64'd1248 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd1248 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd40: time_high_parts = ((((64'd1280 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd1280 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd41: time_high_parts = ((((64'd1312 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd1312 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd42: time_high_parts = ((((64'd1344 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd1344 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd43: time_high_parts = ((((64'd1376 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd1376 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd44: time_high_parts = ((((64'd1408 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd1408 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd45: time_high_parts = ((((64'd1440 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd1440 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd46: time_high_parts = ((((64'd1472 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd1472 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd47: time_high_parts = ((((64'd1504 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd1504 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd48: time_high_parts = ((((64'd1536 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd1536 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd49: time_high_parts = ((((64'd1568 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd1568 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd50: time_high_parts = ((((64'd1600 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd1600 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd51: time_high_parts = ((((64'd1632 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd1632 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd52: time_high_parts = ((((64'd1664 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd1664 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd53: time_high_parts = ((((64'd1696 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd1696 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd54: time_high_parts = ((((64'd1728 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd1728 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd55: time_high_parts = ((((64'd1760 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd1760 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd56: time_high_parts = ((((64'd1792 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd1792 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd57: time_high_parts = ((((64'd1824 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd1824 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd58: time_high_parts = ((((64'd1856 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd1856 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd59: time_high_parts = ((((64'd1888 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd1888 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd60: time_high_parts = ((((64'd1920 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd1920 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd61: time_high_parts = ((((64'd1952 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd1952 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd62: time_high_parts = ((((64'd1984 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd1984 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd63: time_high_parts = ((((64'd2016 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd2016 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd64: time_high_parts = ((((64'd2048 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd2048 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd65: time_high_parts = ((((64'd2080 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd2080 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd66: time_high_parts = ((((64'd2112 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd2112 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd67: time_high_parts = ((((64'd2144 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd2144 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd68: time_high_parts = ((((64'd2176 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd2176 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd69: time_high_parts = ((((64'd2208 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd2208 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd70: time_high_parts = ((((64'd2240 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd2240 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd71: time_high_parts = ((((64'd2272 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd2272 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd72: time_high_parts = ((((64'd2304 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd2304 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd73: time_high_parts = ((((64'd2336 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd2336 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd74: time_high_parts = ((((64'd2368 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd2368 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd75: time_high_parts = ((((64'd2400 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd2400 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd76: time_high_parts = ((((64'd2432 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd2432 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd77: time_high_parts = ((((64'd2464 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd2464 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd78: time_high_parts = ((((64'd2496 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd2496 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd79: time_high_parts = ((((64'd2528 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd2528 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd80: time_high_parts = ((((64'd2560 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd2560 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd81: time_high_parts = ((((64'd2592 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd2592 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd82: time_high_parts = ((((64'd2624 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd2624 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd83: time_high_parts = ((((64'd2656 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd2656 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd84: time_high_parts = ((((64'd2688 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd2688 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd85: time_high_parts = ((((64'd2720 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd2720 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd86: time_high_parts = ((((64'd2752 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd2752 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd87: time_high_parts = ((((64'd2784 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd2784 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd88: time_high_parts = ((((64'd2816 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd2816 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd89: time_high_parts = ((((64'd2848 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd2848 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd90: time_high_parts = ((((64'd2880 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd2880 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd91: time_high_parts = ((((64'd2912 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd2912 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd92: time_high_parts = ((((64'd2944 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd2944 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd93: time_high_parts = ((((64'd2976 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd2976 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd94: time_high_parts = ((((64'd3008 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd3008 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd95: time_high_parts = ((((64'd3040 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd3040 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd96: time_high_parts = ((((64'd3072 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd3072 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd97: time_high_parts = ((((64'd3104 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd3104 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd98: time_high_parts = ((((64'd3136 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd3136 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd99: time_high_parts = ((((64'd3168 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd3168 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd100: time_high_parts = ((((64'd3200 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd3200 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd101: time_high_parts = ((((64'd3232 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd3232 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd102: time_high_parts = ((((64'd3264 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd3264 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd103: time_high_parts = ((((64'd3296 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd3296 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd104: time_high_parts = ((((64'd3328 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd3328 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd105: time_high_parts = ((((64'd3360 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd3360 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd106: time_high_parts = ((((64'd3392 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd3392 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd107: time_high_parts = ((((64'd3424 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd3424 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd108: time_high_parts = ((((64'd3456 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd3456 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd109: time_high_parts = ((((64'd3488 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd3488 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd110: time_high_parts = ((((64'd3520 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd3520 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd111: time_high_parts = ((((64'd3552 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd3552 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd112: time_high_parts = ((((64'd3584 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd3584 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd113: time_high_parts = ((((64'd3616 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd3616 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd114: time_high_parts = ((((64'd3648 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd3648 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd115: time_high_parts = ((((64'd3680 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd3680 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd116: time_high_parts = ((((64'd3712 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd3712 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd117: time_high_parts = ((((64'd3744 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd3744 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd118: time_high_parts = ((((64'd3776 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd3776 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd119: time_high_parts = ((((64'd3808 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd3808 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd120: time_high_parts = ((((64'd3840 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd3840 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd121: time_high_parts = ((((64'd3872 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd3872 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd122: time_high_parts = ((((64'd3904 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd3904 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd123: time_high_parts = ((((64'd3936 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd3936 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd124: time_high_parts = ((((64'd3968 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd3968 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd125: time_high_parts = ((((64'd4000 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd4000 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd126: time_high_parts = ((((64'd4032 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd4032 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd127: time_high_parts = ((((64'd4064 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd4064 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd128: time_high_parts = ((((64'd4096 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd4096 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd129: time_high_parts = ((((64'd4128 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd4128 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd130: time_high_parts = ((((64'd4160 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd4160 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd131: time_high_parts = ((((64'd4192 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd4192 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd132: time_high_parts = ((((64'd4224 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd4224 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd133: time_high_parts = ((((64'd4256 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd4256 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd134: time_high_parts = ((((64'd4288 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd4288 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd135: time_high_parts = ((((64'd4320 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd4320 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd136: time_high_parts = ((((64'd4352 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd4352 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd137: time_high_parts = ((((64'd4384 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd4384 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd138: time_high_parts = ((((64'd4416 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd4416 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd139: time_high_parts = ((((64'd4448 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd4448 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd140: time_high_parts = ((((64'd4480 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd4480 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd141: time_high_parts = ((((64'd4512 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd4512 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd142: time_high_parts = ((((64'd4544 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd4544 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd143: time_high_parts = ((((64'd4576 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd4576 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd144: time_high_parts = ((((64'd4608 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd4608 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd145: time_high_parts = ((((64'd4640 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd4640 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd146: time_high_parts = ((((64'd4672 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd4672 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd147: time_high_parts = ((((64'd4704 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd4704 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd148: time_high_parts = ((((64'd4736 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd4736 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd149: time_high_parts = ((((64'd4768 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd4768 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd150: time_high_parts = ((((64'd4800 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd4800 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd151: time_high_parts = ((((64'd4832 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd4832 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd152: time_high_parts = ((((64'd4864 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd4864 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd153: time_high_parts = ((((64'd4896 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd4896 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd154: time_high_parts = ((((64'd4928 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd4928 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd155: time_high_parts = ((((64'd4960 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd4960 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd156: time_high_parts = ((((64'd4992 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd4992 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd157: time_high_parts = ((((64'd5024 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd5024 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd158: time_high_parts = ((((64'd5056 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd5056 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd159: time_high_parts = ((((64'd5088 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd5088 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd160: time_high_parts = ((((64'd5120 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd5120 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd161: time_high_parts = ((((64'd5152 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd5152 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd162: time_high_parts = ((((64'd5184 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd5184 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd163: time_high_parts = ((((64'd5216 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd5216 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd164: time_high_parts = ((((64'd5248 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd5248 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd165: time_high_parts = ((((64'd5280 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd5280 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd166: time_high_parts = ((((64'd5312 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd5312 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd167: time_high_parts = ((((64'd5344 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd5344 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd168: time_high_parts = ((((64'd5376 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd5376 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd169: time_high_parts = ((((64'd5408 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd5408 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd170: time_high_parts = ((((64'd5440 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd5440 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd171: time_high_parts = ((((64'd5472 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd5472 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd172: time_high_parts = ((((64'd5504 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd5504 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd173: time_high_parts = ((((64'd5536 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd5536 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd174: time_high_parts = ((((64'd5568 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd5568 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd175: time_high_parts = ((((64'd5600 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd5600 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd176: time_high_parts = ((((64'd5632 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd5632 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd177: time_high_parts = ((((64'd5664 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd5664 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd178: time_high_parts = ((((64'd5696 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd5696 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd179: time_high_parts = ((((64'd5728 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd5728 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd180: time_high_parts = ((((64'd5760 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd5760 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd181: time_high_parts = ((((64'd5792 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd5792 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd182: time_high_parts = ((((64'd5824 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd5824 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd183: time_high_parts = ((((64'd5856 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd5856 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd184: time_high_parts = ((((64'd5888 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd5888 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd185: time_high_parts = ((((64'd5920 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd5920 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd186: time_high_parts = ((((64'd5952 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd5952 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd187: time_high_parts = ((((64'd5984 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd5984 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd188: time_high_parts = ((((64'd6016 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd6016 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd189: time_high_parts = ((((64'd6048 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd6048 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd190: time_high_parts = ((((64'd6080 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd6080 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd191: time_high_parts = ((((64'd6112 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd6112 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd192: time_high_parts = ((((64'd6144 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd6144 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd193: time_high_parts = ((((64'd6176 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd6176 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd194: time_high_parts = ((((64'd6208 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd6208 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd195: time_high_parts = ((((64'd6240 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd6240 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd196: time_high_parts = ((((64'd6272 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd6272 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd197: time_high_parts = ((((64'd6304 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd6304 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd198: time_high_parts = ((((64'd6336 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd6336 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd199: time_high_parts = ((((64'd6368 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd6368 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd200: time_high_parts = ((((64'd6400 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd6400 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd201: time_high_parts = ((((64'd6432 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd6432 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd202: time_high_parts = ((((64'd6464 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd6464 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd203: time_high_parts = ((((64'd6496 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd6496 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd204: time_high_parts = ((((64'd6528 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd6528 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd205: time_high_parts = ((((64'd6560 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd6560 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd206: time_high_parts = ((((64'd6592 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd6592 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd207: time_high_parts = ((((64'd6624 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd6624 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd208: time_high_parts = ((((64'd6656 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd6656 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd209: time_high_parts = ((((64'd6688 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd6688 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd210: time_high_parts = ((((64'd6720 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd6720 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd211: time_high_parts = ((((64'd6752 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd6752 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd212: time_high_parts = ((((64'd6784 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd6784 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd213: time_high_parts = ((((64'd6816 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd6816 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd214: time_high_parts = ((((64'd6848 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd6848 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd215: time_high_parts = ((((64'd6880 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd6880 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd216: time_high_parts = ((((64'd6912 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd6912 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd217: time_high_parts = ((((64'd6944 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd6944 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd218: time_high_parts = ((((64'd6976 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd6976 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd219: time_high_parts = ((((64'd7008 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd7008 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd220: time_high_parts = ((((64'd7040 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd7040 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd221: time_high_parts = ((((64'd7072 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd7072 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd222: time_high_parts = ((((64'd7104 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd7104 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd223: time_high_parts = ((((64'd7136 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd7136 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd224: time_high_parts = ((((64'd7168 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd7168 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd225: time_high_parts = ((((64'd7200 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd7200 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd226: time_high_parts = ((((64'd7232 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd7232 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd227: time_high_parts = ((((64'd7264 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd7264 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd228: time_high_parts = ((((64'd7296 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd7296 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd229: time_high_parts = ((((64'd7328 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd7328 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd230: time_high_parts = ((((64'd7360 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd7360 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd231: time_high_parts = ((((64'd7392 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd7392 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd232: time_high_parts = ((((64'd7424 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd7424 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd233: time_high_parts = ((((64'd7456 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd7456 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd234: time_high_parts = ((((64'd7488 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd7488 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd235: time_high_parts = ((((64'd7520 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd7520 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd236: time_high_parts = ((((64'd7552 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd7552 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd237: time_high_parts = ((((64'd7584 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd7584 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd238: time_high_parts = ((((64'd7616 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd7616 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd239: time_high_parts = ((((64'd7648 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd7648 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd240: time_high_parts = ((((64'd7680 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd7680 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd241: time_high_parts = ((((64'd7712 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd7712 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd242: time_high_parts = ((((64'd7744 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd7744 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd243: time_high_parts = ((((64'd7776 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd7776 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd244: time_high_parts = ((((64'd7808 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd7808 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd245: time_high_parts = ((((64'd7840 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd7840 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd246: time_high_parts = ((((64'd7872 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd7872 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd247: time_high_parts = ((((64'd7904 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd7904 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd248: time_high_parts = ((((64'd7936 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd7936 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd249: time_high_parts = ((((64'd7968 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd7968 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd250: time_high_parts = ((((64'd8000 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd8000 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd251: time_high_parts = ((((64'd8032 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd8032 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd252: time_high_parts = ((((64'd8064 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd8064 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd253: time_high_parts = ((((64'd8096 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd8096 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd254: time_high_parts = ((((64'd8128 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd8128 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                8'd255: time_high_parts = ((((64'd8160 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd8160 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                default: time_high_parts = 42'd0;
            endcase
        end
    endfunction
    function [41:0] time_low_parts;
        input [4:0] index;
        begin
            case (index)
                5'd0: time_low_parts = ((((64'd0 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd0 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                5'd1: time_low_parts = ((((64'd1 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd1 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                5'd2: time_low_parts = ((((64'd2 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd2 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                5'd3: time_low_parts = ((((64'd3 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd3 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                5'd4: time_low_parts = ((((64'd4 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd4 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                5'd5: time_low_parts = ((((64'd5 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd5 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                5'd6: time_low_parts = ((((64'd6 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd6 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                5'd7: time_low_parts = ((((64'd7 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd7 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                5'd8: time_low_parts = ((((64'd8 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd8 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                5'd9: time_low_parts = ((((64'd9 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd9 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                5'd10: time_low_parts = ((((64'd10 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd10 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                5'd11: time_low_parts = ((((64'd11 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd11 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                5'd12: time_low_parts = ((((64'd12 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd12 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                5'd13: time_low_parts = ((((64'd13 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd13 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                5'd14: time_low_parts = ((((64'd14 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd14 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                5'd15: time_low_parts = ((((64'd15 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd15 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                5'd16: time_low_parts = ((((64'd16 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd16 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                5'd17: time_low_parts = ((((64'd17 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd17 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                5'd18: time_low_parts = ((((64'd18 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd18 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                5'd19: time_low_parts = ((((64'd19 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd19 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                5'd20: time_low_parts = ((((64'd20 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd20 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                5'd21: time_low_parts = ((((64'd21 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd21 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                5'd22: time_low_parts = ((((64'd22 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd22 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                5'd23: time_low_parts = ((((64'd23 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd23 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                5'd24: time_low_parts = ((((64'd24 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd24 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                5'd25: time_low_parts = ((((64'd25 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd25 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                5'd26: time_low_parts = ((((64'd26 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd26 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                5'd27: time_low_parts = ((((64'd27 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd27 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                5'd28: time_low_parts = ((((64'd28 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd28 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                5'd29: time_low_parts = ((((64'd29 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd29 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                5'd30: time_low_parts = ((((64'd30 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd30 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                5'd31: time_low_parts = ((((64'd31 * TIME_SAMPLE_RATE_HZ) / 64'd1000) << 10) | ((64'd31 * TIME_SAMPLE_RATE_HZ) % 64'd1000));
                default: time_low_parts = 42'd0;
            endcase
        end
    endfunction


    // synthesis translate_off
    initial
    begin
        if ((SMP_TICK_FREQ < 1000) || (SMP_TICK_FREQ > 209715))
            $fatal(1, "SMP_TICK_FREQ must be 1000..209715 Hz for 1..5000 ms and 20-bit samples");
    end
    // synthesis translate_on

    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            attack_high_part_r <= 42'd0;
            attack_low_part_r <= 42'd0;
            decay_high_part_r <= 42'd0;
            decay_low_part_r <= 42'd0;
            release_high_part_r <= 42'd0;
            release_low_part_r <= 42'd0;
            wavetable_0_captured <= 4'd0;
            wavetable_1_captured <= 4'd0;
            interp_percent_captured <= 7'd0;
            phase_degrees_captured <= 9'd0;
            attack_ms_captured <= 11'd0;
            decay_ms_captured <= 11'd0;
            sustain_percent_captured <= 7'd0;
            release_ms_captured <= 13'd0;
            master_gain_captured <= 16'h8000;
            balance_gain_captured <= 16'h8000;
            advanced_captured_r <= 128'h001840008000100090002ee02800b000;
            advanced_encoded_r <= 128'h001840008000100090002ee02800b000;
            make_up_captured_r <= {4{16'h8000}};
            make_up_encoded_r <= {4{16'h8000}};
            reverb_mix_percent_captured <= 7'd0;
            delay_mix_percent_captured <= 7'd0;
            distortion_mix_percent_captured <= 7'd0;
            chorus_mix_percent_captured <= 7'd0;
            wavetable_0_encoded_r <= 4'd0;
            wavetable_1_encoded_r <= 4'd0;
            wavetable_interp_encoded_r <= 16'd0;
            init_phase_encoded_r <= 16'd0;
            attack_ticks_encoded_r <= 20'd0;
            decay_ticks_encoded_r <= 20'd0;
            sustain_level_encoded_r <= 16'd0;
            release_ticks_encoded_r <= 20'd0;
            master_volume_encoded_r <= 16'h8000;
            balance_volume_encoded_r <= 16'h8000;
            reverb_mix_encoded_r <= 16'd0;
            delay_mix_encoded_r <= 16'd0;
            distortion_mix_encoded_r <= 16'd0;
            chorus_mix_encoded_r <= 16'd0;
        end
        else
        begin
            if (in_valid && in_ready)
            begin
                wavetable_0_captured <= wavetable_0[0];
                wavetable_1_captured <= wavetable_1[0];
                interp_percent_captured <= interp_percent[0];
                phase_degrees_captured <= phase_degrees[0];
                attack_ms_captured <= attack_ms[0];
                decay_ms_captured <= decay_ms[0];
                sustain_percent_captured <= sustain_percent[0];
                release_ms_captured <= release_ms[0];
                master_gain_captured <= master_gain;
                balance_gain_captured <= balance_gain;
                advanced_captured_r <= advanced_parameters;
                make_up_captured_r <= make_up_gains;
                reverb_mix_percent_captured <= reverb_mix_percent;
                delay_mix_percent_captured <= delay_mix_percent;
                distortion_mix_percent_captured <= distortion_mix_percent;
                chorus_mix_percent_captured <= chorus_mix_percent;
            end
            // 第一转换拍读取商余数表；第二拍合并，所有字段一起发布。
            if (current_state == STATE_READ_TIME_PARTS)
            begin
                attack_high_part_r <= time_high_parts({2'd0,attack_ms_captured[10:5]});
                attack_low_part_r <= time_low_parts(attack_ms_captured[4:0]);
                decay_high_part_r <= time_high_parts({2'd0,decay_ms_captured[10:5]});
                decay_low_part_r <= time_low_parts(decay_ms_captured[4:0]);
                release_high_part_r <= time_high_parts(release_ms_captured[12:5]);
                release_low_part_r <= time_low_parts(release_ms_captured[4:0]);
            end
            if (current_state == STATE_CONVERT_SNAPSHOT)
            begin
                wavetable_0_encoded_r <= wavetable_0_captured;
                wavetable_1_encoded_r <= wavetable_1_captured;
                wavetable_interp_encoded_r <= encode_interp(interp_percent_captured);
                init_phase_encoded_r <= encode_phase(phase_degrees_captured);
                attack_ticks_encoded_r <= (attack_sample_count > 32'd1048575) ? 20'hFFFFF : attack_sample_count[19:0];
                decay_ticks_encoded_r <= (decay_sample_count > 32'd1048575) ? 20'hFFFFF : decay_sample_count[19:0];
                sustain_level_encoded_r <= encode_percent(sustain_percent_captured);
                release_ticks_encoded_r <= (release_sample_count > 32'd1048575) ? 20'hFFFFF : release_sample_count[19:0];
                master_volume_encoded_r <= master_gain_captured;
                balance_volume_encoded_r <= balance_gain_captured;
                advanced_encoded_r <= advanced_captured_r;
                make_up_encoded_r <= make_up_captured_r;
                reverb_mix_encoded_r <= encode_percent(reverb_mix_percent_captured);
                delay_mix_encoded_r <= encode_percent(delay_mix_percent_captured);
                distortion_mix_encoded_r <= encode_percent(distortion_mix_percent_captured);
                chorus_mix_encoded_r <= encode_percent(chorus_mix_percent_captured);
            end
        end
    end
endmodule
