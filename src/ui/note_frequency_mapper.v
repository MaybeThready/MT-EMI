/**
 * 2026-11-02 S2和弦接口/逻辑变动：输入由物理key_id改为7位note_number，31项十二平均律UQ16.16查表覆盖60～90；原24音编码不变，单拍计算与背压协议不变。
 */
/**
 * note_frequency_mapper 模块 v2
 * v2版本修改：去掉装载使能中重复的复位判断，频率和延迟不变。
 * 把MIDI音高60～90换算为频率，涵盖C4～F♯6，A4为69。
 * note_number/occupied: 每声部7位音高及占用；未占用或音高非法时输出零。
 * note_freq: 32 位 UQ16.16，编码为 round(频率 × 65536)，A4 为 440 Hz。
 * 输入握手后下一周期结果有效；等待接收时保持，复位清零。
 * NOTE: 由 generate_note_frequency.py 生成查表，不包含弯音或时钟误差补偿。
 */
module note_frequency_mapper
#(
    parameter KEY_NUM = 24,  // 琴键数量，1～24，按 C4 起连续编号
    parameter MAX_POLYPHONY = 32,  // 声部数量，默认 32
    parameter KEY_ID_WIDTH = (KEY_NUM > 1) ? $clog2(KEY_NUM) : 1  // 琴键编号位宽，至少为 1
)(
    input clk_sys,
    input rst_n,
    input [6:0] note_number [MAX_POLYPHONY-1:0],
    input [MAX_POLYPHONY-1:0] occupied,
    input in_valid,
    output in_ready,
    output [31:0] note_freq [MAX_POLYPHONY-1:0],
    output out_valid,
    input out_ready
) /* synthesis syn_romstyle = "logic" */;
    localparam STATE_WAIT_MAPPING = 1'b0;
    localparam STATE_WAIT_RESULT_ACCEPT = 1'b1;
    wire current_state;
    reg next_state;
    reg [31:0] frequency_r [MAX_POLYPHONY-1:0];
    integer voice;
    genvar voice_index;
    function [31:0] frequency_code;
        input [6:0] midi_note;
        begin
            case (midi_note)
                7'd60: frequency_code = 32'd17145893;  // 261.625565301 Hz
                7'd61: frequency_code = 32'd18165441;  // 277.182630977 Hz
                7'd62: frequency_code = 32'd19245614;  // 293.664767917 Hz
                7'd63: frequency_code = 32'd20390018;  // 311.126983722 Hz
                7'd64: frequency_code = 32'd21602472;  // 329.627556913 Hz
                7'd65: frequency_code = 32'd22887021;  // 349.228231433 Hz
                7'd66: frequency_code = 32'd24247954;  // 369.994422712 Hz
                7'd67: frequency_code = 32'd25689813;  // 391.995435982 Hz
                7'd68: frequency_code = 32'd27217409;  // 415.304697580 Hz
                7'd69: frequency_code = 32'd28835840;  // 440.000000000 Hz
                7'd70: frequency_code = 32'd30550508;  // 466.163761518 Hz
                7'd71: frequency_code = 32'd32367136;  // 493.883301256 Hz
                7'd72: frequency_code = 32'd34291786;  // 523.251130601 Hz
                7'd73: frequency_code = 32'd36330882;  // 554.365261954 Hz
                7'd74: frequency_code = 32'd38491228;  // 587.329535835 Hz
                7'd75: frequency_code = 32'd40780036;  // 622.253967444 Hz
                7'd76: frequency_code = 32'd43204943;  // 659.255113826 Hz
                7'd77: frequency_code = 32'd45774043;  // 698.456462866 Hz
                7'd78: frequency_code = 32'd48495909;  // 739.988845423 Hz
                7'd79: frequency_code = 32'd51379626;  // 783.990871963 Hz
                7'd80: frequency_code = 32'd54434817;  // 830.609395160 Hz
                7'd81: frequency_code = 32'd57671680;  // 880.000000000 Hz
                7'd82: frequency_code = 32'd61101017;  // 932.327523036 Hz
                7'd83: frequency_code = 32'd64734272;  // 987.766602512 Hz
                7'd84: frequency_code = 32'd68583572;  // 1046.502261202 Hz
                7'd85: frequency_code = 32'd72661764;  // 1108.730523907 Hz
                7'd86: frequency_code = 32'd76982457;  // 1174.659071670 Hz
                7'd87: frequency_code = 32'd81560072;  // 1244.507934888 Hz
                7'd88: frequency_code = 32'd86409886;  // 1318.510227651 Hz
                7'd89: frequency_code = 32'd91548086;  // 1396.912925732 Hz
                7'd90: frequency_code = 32'd96991818;  // 1479.977690847 Hz
                default: frequency_code = 32'd0;
            endcase
        end
    endfunction
    assign in_ready = rst_n && (current_state == STATE_WAIT_MAPPING);
    // 复位状态本身无有效结果；异步复位仍保留在状态与数据寄存器。
    assign out_valid = (current_state == STATE_WAIT_RESULT_ACCEPT);
    generate
        for (voice_index = 0; voice_index < MAX_POLYPHONY; voice_index = voice_index + 1)
        begin : frequency_outputs
            assign note_freq[voice_index] = frequency_r[voice_index];
        end
    endgenerate
    fsm #(.W(1), .INITIAL_STATE(STATE_WAIT_MAPPING)) fsm_u (
        .clk(clk_sys), .rst_n(rst_n), .stn(next_state), .stc(current_state)
    );
    always @(*)
    begin
        case (current_state)
            STATE_WAIT_MAPPING: next_state = in_valid ? STATE_WAIT_RESULT_ACCEPT : STATE_WAIT_MAPPING;
            STATE_WAIT_RESULT_ACCEPT: next_state = out_ready ? STATE_WAIT_MAPPING : STATE_WAIT_RESULT_ACCEPT;
            default: next_state = STATE_WAIT_MAPPING;
        endcase
    end
    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            for (voice = 0; voice < MAX_POLYPHONY; voice = voice + 1)
                frequency_r[voice] <= 32'd0;
        end
        // 外层已处理异步复位；内部使能不再绕行含 rst_n 的公开 ready。
        else if (in_valid && (current_state == STATE_WAIT_MAPPING))
        begin
            for (voice = 0; voice < MAX_POLYPHONY; voice = voice + 1)
                frequency_r[voice] <= (occupied[voice] && note_number[voice] >= 7'd60 && note_number[voice] <= 7'd90) ?
                    frequency_code(note_number[voice]) : 32'd0;
        end
    end
    // synthesis translate_off
    initial
    begin
        if ((KEY_NUM < 1) || (KEY_NUM > 24) || (MAX_POLYPHONY < 1))
            $fatal(1, "非法音高映射配置");
    end
    // synthesis translate_on
endmodule
