/**
 * 2026-10-31：两路增益统一UQ1.15，默认1.0（8000）；音色只保存balance，不保存master。
 * 音色记录封装和校验模块 v2：64 字节记录，CRC-16 每系统周期计算一位。
 * v2 版本修改：结果 valid 不再重复判断复位，状态机仍异步复位到等待请求。
 * decode=0 封装，decode=1 校验；输入／输出均按 valid && ready 交付。
 * NOTE: 基础192位、高级128位、音色增益16位和四路补偿64位随同一握手交付，不含master_volume。
 * 新记录格式6/字段数25：字4..15基础、16..23高级、24音色增益、25..28四路补偿、29..30保留零。
 * 兼容格式3/13项与4/21项、5/21项：旧格式的四路补偿均恢复为1.0。
 * 格式1/2及未知版本拒绝；CRC、槽号、字段范围和保留位仍严格检查。
 * CRC: 多项式 0x1021，初值 0xffff，从 bit495 到 bit0，无反射／最终异或。
 * CRC移位缓存由本地准备状态装载，接收请求后增加一拍；输入不需额外保持。
 * status: 0 正常、1 CRC 错、2 格式错、3 范围错、4 不支持的扩展。
 */
module preset_record_codec
(
    input clk_sys,
    input rst_n,
    input decode,
    input [3:0] slot,
    input [127:0] advanced_parameters,  // 字16..23，S2音频编码
    output [127:0] advanced_parameters_out,
    input [191:0] parameters,
    input [15:0] balance_gain,  // UQ1.15，0000..FFFF，随音色保存；与演奏总音量独立
    input [63:0] make_up_gains,  // {合唱, 失真, 延迟, 混响}，各 UQ1.15
    input [511:0] record_in,
    input in_valid,
    output in_ready,
    output [511:0] record_out,
    output [191:0] parameters_out,
    output [15:0] balance_gain_out,
    output [63:0] make_up_gains_out,
    output [2:0] status,
    output out_valid,
    input out_ready
);
    localparam STATE_WAIT_REQUEST = 3'd0;
    localparam STATE_CALCULATE_CRC = 3'd1;
    localparam STATE_CHECK_RECORD = 3'd2;
    localparam STATE_WAIT_RESULT_ACCEPT = 3'd3;
    localparam STATE_PREPARE_CRC = 3'd4;
    wire [2:0] current_state;
    reg [2:0] next_state;
    reg decode_r;
    reg [3:0] slot_r;
    reg [511:0] record_r;
    reg [495:0] crc_shift_r;
    reg [15:0] crc_r;
    reg [8:0] bits_remaining_r;
    reg [2:0] status_r;
    wire [15:0] crc_next;
    wire [191:0] parameter_words;
    wire invalid_range;
    localparam [127:0] DEFAULT_ADVANCED = 128'h001840008000100090002ee02800b000;
    wire legacy_gain = (record_r[31:16] == 16'd3) || (record_r[31:16] == 16'd4);
    wire legacy_record = (record_r[31:16] == 16'd3) && (record_r[63:48] == 16'd13);
    assign advanced_parameters_out = legacy_record ? DEFAULT_ADVANCED : record_r[383:256];

    // 旧字24为百分比；四舍五入查表转换Q15，100%映射8000。越界由invalid_range拒绝。
    function [15:0] legacy_gain_to_q15;
        input [15:0] percent;
        begin
            case (percent)
                16'd0: legacy_gain_to_q15 = 16'd0;
                16'd1: legacy_gain_to_q15 = 16'd328;
                16'd2: legacy_gain_to_q15 = 16'd655;
                16'd3: legacy_gain_to_q15 = 16'd983;
                16'd4: legacy_gain_to_q15 = 16'd1311;
                16'd5: legacy_gain_to_q15 = 16'd1638;
                16'd6: legacy_gain_to_q15 = 16'd1966;
                16'd7: legacy_gain_to_q15 = 16'd2294;
                16'd8: legacy_gain_to_q15 = 16'd2621;
                16'd9: legacy_gain_to_q15 = 16'd2949;
                16'd10: legacy_gain_to_q15 = 16'd3277;
                16'd11: legacy_gain_to_q15 = 16'd3604;
                16'd12: legacy_gain_to_q15 = 16'd3932;
                16'd13: legacy_gain_to_q15 = 16'd4260;
                16'd14: legacy_gain_to_q15 = 16'd4588;
                16'd15: legacy_gain_to_q15 = 16'd4915;
                16'd16: legacy_gain_to_q15 = 16'd5243;
                16'd17: legacy_gain_to_q15 = 16'd5571;
                16'd18: legacy_gain_to_q15 = 16'd5898;
                16'd19: legacy_gain_to_q15 = 16'd6226;
                16'd20: legacy_gain_to_q15 = 16'd6554;
                16'd21: legacy_gain_to_q15 = 16'd6881;
                16'd22: legacy_gain_to_q15 = 16'd7209;
                16'd23: legacy_gain_to_q15 = 16'd7537;
                16'd24: legacy_gain_to_q15 = 16'd7864;
                16'd25: legacy_gain_to_q15 = 16'd8192;
                16'd26: legacy_gain_to_q15 = 16'd8520;
                16'd27: legacy_gain_to_q15 = 16'd8847;
                16'd28: legacy_gain_to_q15 = 16'd9175;
                16'd29: legacy_gain_to_q15 = 16'd9503;
                16'd30: legacy_gain_to_q15 = 16'd9830;
                16'd31: legacy_gain_to_q15 = 16'd10158;
                16'd32: legacy_gain_to_q15 = 16'd10486;
                16'd33: legacy_gain_to_q15 = 16'd10813;
                16'd34: legacy_gain_to_q15 = 16'd11141;
                16'd35: legacy_gain_to_q15 = 16'd11469;
                16'd36: legacy_gain_to_q15 = 16'd11796;
                16'd37: legacy_gain_to_q15 = 16'd12124;
                16'd38: legacy_gain_to_q15 = 16'd12452;
                16'd39: legacy_gain_to_q15 = 16'd12780;
                16'd40: legacy_gain_to_q15 = 16'd13107;
                16'd41: legacy_gain_to_q15 = 16'd13435;
                16'd42: legacy_gain_to_q15 = 16'd13763;
                16'd43: legacy_gain_to_q15 = 16'd14090;
                16'd44: legacy_gain_to_q15 = 16'd14418;
                16'd45: legacy_gain_to_q15 = 16'd14746;
                16'd46: legacy_gain_to_q15 = 16'd15073;
                16'd47: legacy_gain_to_q15 = 16'd15401;
                16'd48: legacy_gain_to_q15 = 16'd15729;
                16'd49: legacy_gain_to_q15 = 16'd16056;
                16'd50: legacy_gain_to_q15 = 16'd16384;
                16'd51: legacy_gain_to_q15 = 16'd16712;
                16'd52: legacy_gain_to_q15 = 16'd17039;
                16'd53: legacy_gain_to_q15 = 16'd17367;
                16'd54: legacy_gain_to_q15 = 16'd17695;
                16'd55: legacy_gain_to_q15 = 16'd18022;
                16'd56: legacy_gain_to_q15 = 16'd18350;
                16'd57: legacy_gain_to_q15 = 16'd18678;
                16'd58: legacy_gain_to_q15 = 16'd19005;
                16'd59: legacy_gain_to_q15 = 16'd19333;
                16'd60: legacy_gain_to_q15 = 16'd19661;
                16'd61: legacy_gain_to_q15 = 16'd19988;
                16'd62: legacy_gain_to_q15 = 16'd20316;
                16'd63: legacy_gain_to_q15 = 16'd20644;
                16'd64: legacy_gain_to_q15 = 16'd20972;
                16'd65: legacy_gain_to_q15 = 16'd21299;
                16'd66: legacy_gain_to_q15 = 16'd21627;
                16'd67: legacy_gain_to_q15 = 16'd21955;
                16'd68: legacy_gain_to_q15 = 16'd22282;
                16'd69: legacy_gain_to_q15 = 16'd22610;
                16'd70: legacy_gain_to_q15 = 16'd22938;
                16'd71: legacy_gain_to_q15 = 16'd23265;
                16'd72: legacy_gain_to_q15 = 16'd23593;
                16'd73: legacy_gain_to_q15 = 16'd23921;
                16'd74: legacy_gain_to_q15 = 16'd24248;
                16'd75: legacy_gain_to_q15 = 16'd24576;
                16'd76: legacy_gain_to_q15 = 16'd24904;
                16'd77: legacy_gain_to_q15 = 16'd25231;
                16'd78: legacy_gain_to_q15 = 16'd25559;
                16'd79: legacy_gain_to_q15 = 16'd25887;
                16'd80: legacy_gain_to_q15 = 16'd26214;
                16'd81: legacy_gain_to_q15 = 16'd26542;
                16'd82: legacy_gain_to_q15 = 16'd26870;
                16'd83: legacy_gain_to_q15 = 16'd27197;
                16'd84: legacy_gain_to_q15 = 16'd27525;
                16'd85: legacy_gain_to_q15 = 16'd27853;
                16'd86: legacy_gain_to_q15 = 16'd28180;
                16'd87: legacy_gain_to_q15 = 16'd28508;
                16'd88: legacy_gain_to_q15 = 16'd28836;
                16'd89: legacy_gain_to_q15 = 16'd29164;
                16'd90: legacy_gain_to_q15 = 16'd29491;
                16'd91: legacy_gain_to_q15 = 16'd29819;
                16'd92: legacy_gain_to_q15 = 16'd30147;
                16'd93: legacy_gain_to_q15 = 16'd30474;
                16'd94: legacy_gain_to_q15 = 16'd30802;
                16'd95: legacy_gain_to_q15 = 16'd31130;
                16'd96: legacy_gain_to_q15 = 16'd31457;
                16'd97: legacy_gain_to_q15 = 16'd31785;
                16'd98: legacy_gain_to_q15 = 16'd32113;
                16'd99: legacy_gain_to_q15 = 16'd32440;
                16'd100: legacy_gain_to_q15 = 16'd32768;
                default: legacy_gain_to_q15 = 16'h8000;
            endcase
        end
    endfunction

    assign crc_next = {crc_r[14:0], 1'b0} ^
        ((crc_r[15] ^ crc_shift_r[495]) ? 16'h1021 : 16'd0);
    assign parameter_words = record_r[255:64];
    assign invalid_range =
        (parameter_words[15:0] > 16'd3) || (parameter_words[31:16] > 16'd3) ||
        (parameter_words[47:32] > 16'd100) || (parameter_words[63:48] > 16'd359) ||
        (parameter_words[79:64] < 16'd1) || (parameter_words[79:64] > 16'd2000) ||
        (parameter_words[95:80] < 16'd1) || (parameter_words[95:80] > 16'd2000) ||
        (parameter_words[111:96] > 16'd100) || (parameter_words[127:112] > 16'd5000) ||
        (parameter_words[143:128] > 16'd100) || (parameter_words[159:144] > 16'd100) ||
        (parameter_words[175:160] > 16'd100) || (parameter_words[191:176] > 16'd100) || (legacy_gain && (record_r[399:384] > 16'd100)) ||
        (!legacy_record && ((record_r[271:256] > 16'hf000) ||
        (record_r[287:272] > 16'hf000) || (record_r[303:288] == 16'd0) ||
        (record_r[319:304] > 16'hf000) || (record_r[335:320] < 16'h1000) ||
        (record_r[335:320] > 16'hf000) || (record_r[383:368] > 16'd255)));
    assign in_ready = rst_n && (current_state == STATE_WAIT_REQUEST);
    // 复位状态不是结果有效状态，避免复位经 valid 进入下游数据使能。
    assign out_valid = (current_state == STATE_WAIT_RESULT_ACCEPT);
    assign record_out = record_r;
    assign parameters_out = parameter_words;
    assign balance_gain_out = legacy_gain ? legacy_gain_to_q15(record_r[399:384]) : record_r[399:384];
    assign make_up_gains_out = (record_r[31:16] == 16'd6) ? record_r[463:400] : {4{16'h8000}};
    assign status = status_r;
    fsm #(.W(3), .INITIAL_STATE(STATE_WAIT_REQUEST)) fsm_u (
        .clk(clk_sys), .rst_n(rst_n), .stn(next_state), .stc(current_state)
    );
    always @(*)
    begin
        next_state = current_state;
        case (current_state)
            STATE_WAIT_REQUEST:
                if (in_valid) next_state = STATE_PREPARE_CRC;
            STATE_PREPARE_CRC: next_state = STATE_CALCULATE_CRC;
            STATE_CALCULATE_CRC:
                if (bits_remaining_r == 9'd1) next_state = STATE_CHECK_RECORD;
            STATE_CHECK_RECORD: next_state = STATE_WAIT_RESULT_ACCEPT;
            STATE_WAIT_RESULT_ACCEPT:
                if (out_ready) next_state = STATE_WAIT_REQUEST;
            default: next_state = STATE_WAIT_REQUEST;
        endcase
    end
    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            decode_r <= 1'b0;
            slot_r <= 4'd0;
            record_r <= 512'd0;
            crc_shift_r <= 496'd0;
            crc_r <= 16'hffff;
            bits_remaining_r <= 9'd0;
            status_r <= 3'd0;
        end
        else
        begin
            case (current_state)
                STATE_WAIT_REQUEST:
                begin
                    if (in_valid)
                    begin
                        decode_r <= decode;
                        slot_r <= slot;
                        record_r <= decode ? record_in :
                            {48'd0, make_up_gains, balance_gain, advanced_parameters, parameters, 16'd25, 12'd0, slot, 16'd6, 16'h5549};
                        crc_r <= 16'hffff;
                        bits_remaining_r <= 9'd496;
                        status_r <= 3'd0;
                    end
                end
                // 请求已锁存到record_r，本地状态驱动496位装载／移位使能。
                STATE_PREPARE_CRC: crc_shift_r <= record_r[495:0];
                STATE_CALCULATE_CRC:
                begin
                    crc_r <= crc_next;
                    crc_shift_r <= {crc_shift_r[494:0], 1'b0};
                    bits_remaining_r <= bits_remaining_r - 9'd1;
                end
                STATE_CHECK_RECORD:
                begin
                    if (!decode_r) record_r[511:496] <= crc_r;
                    if (decode_r && (record_r[511:496] != crc_r)) status_r <= 3'd1;
                    else if ((record_r[15:0] != 16'h5549) ||
                        (!legacy_record && (((record_r[31:16] != 16'd4) && (record_r[31:16] != 16'd5) && (record_r[31:16] != 16'd6)) ||
                        ((record_r[31:16] == 16'd6) ? (record_r[63:48] != 16'd25) : (record_r[63:48] != 16'd21)))) ||
                        (record_r[47:32] != {12'd0, slot_r}))
                        status_r <= 3'd2;
                    else if (invalid_range) status_r <= 3'd3;
                    else if ((legacy_record && (record_r[383:256] != 128'd0)) ||
                        ((record_r[31:16] == 16'd6) ? (record_r[495:464] != 32'd0) : (record_r[495:400] != 96'd0)))
                        status_r <= 3'd4;
                end
                default:
                begin
                    // 保持结果直到下游接收。
                end
            endcase
        end
    end
endmodule
