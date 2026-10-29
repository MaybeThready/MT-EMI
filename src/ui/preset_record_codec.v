/**
 * 音色记录封装和校验模块 v2：64 字节记录，CRC-16 每系统周期计算一位。
 * v2 版本修改：结果 valid 不再重复判断复位，状态机仍异步复位到等待请求。
 * decode=0 封装，decode=1 校验；输入／输出均按 valid && ready 交付。
 * NOTE: 本轮单独增加 balance_percent（音色增益百分比），与12项参数同拍快照/装载；不含 master_volume。
 * 记录格式3/字段数13：字24存 balance_percent，字16..23与25..30仍须为零。
 * 格式2保留给后续完整S2方案；本轮不实现高级参数，也不静默兼容旧格式1。
 * parameters 为 12 个 16 位整数字段，低字起依次为两波形、插值百分比、
 * 初相角度、A/D 毫秒、S 百分比、R 毫秒及四个干湿比；不含总音量。
 * record 低字起为魔数、版本、槽号、字段数、12字参数、8字保留、音色增益、6字保留及CRC。
 * CRC: 多项式 0x1021，初值 0xffff，从 bit495 到 bit0，无反射／最终异或。
 * status: 0 正常、1 CRC 错、2 格式错、3 范围错、4 不支持的扩展。
 */
module preset_record_codec
(
    input clk_sys,
    input rst_n,
    input decode,
    input [3:0] slot,
    input [191:0] parameters,
    input [6:0] balance_percent,  // 0..100，随音色保存；与演奏总音量独立
    input [511:0] record_in,
    input in_valid,
    output in_ready,
    output [511:0] record_out,
    output [191:0] parameters_out,
    output [6:0] balance_percent_out,
    output [2:0] status,
    output out_valid,
    input out_ready
);
    localparam STATE_WAIT_REQUEST = 2'd0;
    localparam STATE_CALCULATE_CRC = 2'd1;
    localparam STATE_CHECK_RECORD = 2'd2;
    localparam STATE_WAIT_RESULT_ACCEPT = 2'd3;
    wire [1:0] current_state;
    reg [1:0] next_state;
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
        (parameter_words[175:160] > 16'd100) || (parameter_words[191:176] > 16'd100) || (record_r[399:384] > 16'd100);
    assign in_ready = rst_n && (current_state == STATE_WAIT_REQUEST);
    // 复位状态不是结果有效状态，避免复位经 valid 进入下游数据使能。
    assign out_valid = (current_state == STATE_WAIT_RESULT_ACCEPT);
    assign record_out = record_r;
    assign parameters_out = parameter_words;
    assign balance_percent_out = record_r[390:384];
    assign status = status_r;
    fsm #(.W(2), .INITIAL_STATE(STATE_WAIT_REQUEST)) fsm_u (
        .clk(clk_sys), .rst_n(rst_n), .stn(next_state), .stc(current_state)
    );
    always @(*)
    begin
        next_state = current_state;
        case (current_state)
            STATE_WAIT_REQUEST:
                if (in_valid) next_state = STATE_CALCULATE_CRC;
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
                            {112'd0, 9'd0, balance_percent, 128'd0, parameters, 16'd13, 12'd0, slot, 16'd3, 16'h5549};
                        crc_shift_r <= decode ? record_in[495:0] :
                            {96'd0, 9'd0, balance_percent, 128'd0, parameters, 16'd13, 12'd0, slot, 16'd3, 16'h5549};
                        crc_r <= 16'hffff;
                        bits_remaining_r <= 9'd496;
                        status_r <= 3'd0;
                    end
                end
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
                    else if ((record_r[15:0] != 16'h5549) || (record_r[31:16] != 16'd3) ||
                        (record_r[47:32] != {12'd0, slot_r}) || (record_r[63:48] != 16'd13))
                        status_r <= 3'd2;
                    else if (invalid_range) status_r <= 3'd3;
                    else if ((record_r[383:256] != 128'd0) || (record_r[495:400] != 96'd0)) status_r <= 3'd4;
                end
                default:
                begin
                    // 保持结果直到下游接收。
                end
            endcase
        end
    end
endmodule
