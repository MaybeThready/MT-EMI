"""以 60 位十进制精度生成 C4～B5 的 UQ16.16；不使用文档已舍入 Hz。"""

import sys
sys.dont_write_bytecode = True
from decimal import Decimal, localcontext, ROUND_HALF_UP
from pathlib import Path
import json

# 生成结果只保存在 ai_workspace，审核后再决定是否替换正式文件。
REPO = Path(__file__).resolve().parents[2]
ROOT = REPO / 'ai_workspace/ui_generated'
for subdir in ('src/ui', 'sim/tb/ui', 'sim/assets', 'sim/assets/system', 'results'):
    (ROOT / subdir).mkdir(parents=True, exist_ok=True)
with localcontext() as ctx:
    ctx.prec = 60
    rows = []
    for key in range(24):
        hz = Decimal(440) * (Decimal(2) ** (Decimal(key - 9) / Decimal(12)))
        code = int((hz * Decimal(65536)).to_integral_value(rounding=ROUND_HALF_UP))
        rows.append({'key_id': key, 'frequency_hz': str(hz), 'uq16_16': code})

rtl = '''/**
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
'''
for row in rows:
    rtl += f"                {row['key_id']}: frequency_code = 32'd{row['uq16_16']};  // 键 {row['key_id']}，{float(row['frequency_hz']):.9f} Hz\n"
rtl += '''                default: frequency_code = 32'd0;
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
'''
(ROOT / 'src/ui/note_frequency_mapper.v').write_text(rtl, encoding='utf-8')
(ROOT / 'results/note_frequency_codes.json').write_text(json.dumps(rows, ensure_ascii=False, indent=2), encoding='utf-8')
