/**
 * 把琴键编号换算成音符频率，24 键对应 C4～B5，A4 为键 9。
 * key_id/occupied: 每个声部的键号及是否已分配；未分配或键号非法时输出零。
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
    input [KEY_ID_WIDTH-1:0] key_id [MAX_POLYPHONY-1:0],
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
        input [KEY_ID_WIDTH-1:0] key_index;
        begin
            case (key_index)
                0: frequency_code = 32'd17145893;  // 键 0，261.625565301 Hz
                1: frequency_code = 32'd18165441;  // 键 1，277.182630977 Hz
                2: frequency_code = 32'd19245614;  // 键 2，293.664767917 Hz
                3: frequency_code = 32'd20390018;  // 键 3，311.126983722 Hz
                4: frequency_code = 32'd21602472;  // 键 4，329.627556913 Hz
                5: frequency_code = 32'd22887021;  // 键 5，349.228231433 Hz
                6: frequency_code = 32'd24247954;  // 键 6，369.994422712 Hz
                7: frequency_code = 32'd25689813;  // 键 7，391.995435982 Hz
                8: frequency_code = 32'd27217409;  // 键 8，415.304697580 Hz
                9: frequency_code = 32'd28835840;  // 键 9，440.000000000 Hz
                10: frequency_code = 32'd30550508;  // 键 10，466.163761518 Hz
                11: frequency_code = 32'd32367136;  // 键 11，493.883301256 Hz
                12: frequency_code = 32'd34291786;  // 键 12，523.251130601 Hz
                13: frequency_code = 32'd36330882;  // 键 13，554.365261954 Hz
                14: frequency_code = 32'd38491228;  // 键 14，587.329535835 Hz
                15: frequency_code = 32'd40780036;  // 键 15，622.253967444 Hz
                16: frequency_code = 32'd43204943;  // 键 16，659.255113826 Hz
                17: frequency_code = 32'd45774043;  // 键 17，698.456462866 Hz
                18: frequency_code = 32'd48495909;  // 键 18，739.988845423 Hz
                19: frequency_code = 32'd51379626;  // 键 19，783.990871963 Hz
                20: frequency_code = 32'd54434817;  // 键 20，830.609395160 Hz
                21: frequency_code = 32'd57671680;  // 键 21，880.000000000 Hz
                22: frequency_code = 32'd61101017;  // 键 22，932.327523036 Hz
                23: frequency_code = 32'd64734272;  // 键 23，987.766602512 Hz
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
        else if (in_valid && in_ready)
        begin
            for (voice = 0; voice < MAX_POLYPHONY; voice = voice + 1)
                frequency_r[voice] <= (occupied[voice] && (key_id[voice] < KEY_NUM)) ?
                    frequency_code(key_id[voice]) : 32'd0;
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
