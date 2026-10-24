"""生成重复的具名参数连线，不自动生成协议逻辑。

所有输出保存在本脚本任务目录内；字段对应公共
架构约定，本阶段每通道数组仅有一个元素。
"""

import sys
sys.dont_write_bytecode = True
from pathlib import Path

# 生成结果只保存在 ai_workspace，审核后再决定是否替换正式文件。
REPO = Path(__file__).resolve().parents[2]
ROOT = REPO / 'ai_workspace/ui_generated'
for subdir in ('src/ui', 'sim/tb/ui', 'sim/assets', 'sim/assets/system', 'results'):
    (ROOT / subdir).mkdir(parents=True, exist_ok=True)
FIELDS = [
    ('wavetable_0', 4, 0, True), ('wavetable_1', 4, 1, True),
    ('interp_percent', 7, 0, True), ('phase_degrees', 9, 0, True),
    ('attack_ms', 11, 5, True), ('decay_ms', 11, 150, True),
    ('sustain_percent', 7, 70, True), ('release_ms', 13, 200, True),
    ('master_percent', 7, 30, False), ('reverb_mix_percent', 7, 0, False),
    ('delay_mix_percent', 7, 0, False), ('distortion_mix_percent', 7, 0, False),
    ('chorus_mix_percent', 7, 0, False),
]
ENCODED = [
    ('wavetable_0', 4, True, 'wavetable_0[0]'),
    ('wavetable_1', 4, True, 'wavetable_1[0]'),
    ('wavetable_interp', 16, True, 'encode_interp(interp_percent[0])'),
    ('init_phase', 16, True, 'encode_phase(phase_degrees[0])'),
    ('attack_ticks', 20, True, 'encode_time(attack_ms[0])'),
    ('decay_ticks', 20, True, 'encode_time(decay_ms[0])'),
    ('sustain_level', 16, True, 'encode_percent(sustain_percent[0])'),
    ('release_ticks', 20, True, 'encode_time(release_ms[0])'),
    ('master_volume', 16, False, 'encode_percent(master_percent)'),
    ('reverb_mix', 16, False, 'encode_percent(reverb_mix_percent)'),
    ('delay_mix', 16, False, 'encode_percent(delay_mix_percent)'),
    ('distortion_mix', 16, False, 'encode_percent(distortion_mix_percent)'),
    ('chorus_mix', 16, False, 'encode_percent(chorus_mix_percent)'),
]

def ports(direction, prefix=''):
    return '\n'.join(f'    {direction} [{w-1}:0] {prefix}{n}' + (' [0:0]' if a else '') + ',' for n,w,_,a in FIELDS)

def write(name, source):
    p = ROOT / 'src/ui' / (name + '.v')
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(source, encoding='utf-8')

def controller():
    s = '''/**
 * 根据旋钮动作修改音色参数，处理粗细调、限幅和恢复默认值。
 * knob_delta: 每路 -1/0/+1 步；mode/fine_adjust: 本次使用的模式及微调开关。
 * 参数按百分比、角度、毫秒保存；按下旋钮恢复默认，优先于同次转动。
 * frame_done_valid: 本次旋钮已处理完成，即使没有修改参数也返回确认。
 * parameter_valid: 有一整组参数可读取；等待时保持，后续修改留到下一组输出。
 * WAVE_SELECT_STEPS: 换一张波形需累计的步数，合法范围 1～32767。
 * TODO: 默认值 0 表示未配置，会阻止正常工作；产品取值待定。
 */
module knob_parameter_controller
#(
    parameter WAVE_SELECT_STEPS = 0  // 换一张波形所需步数；0 表示未配置
)(
    input clk_sys,
    input rst_n,
    input signed [1:0] knob_delta [7:0],
    input [7:0] knob_pressed_event,
    input [1:0] mode,
    input fine_adjust,
    input edit_enable,
    input edit_target,
    input clear_wave_progress,
    input in_valid,
    output in_ready,
    output frame_done_valid,
    input frame_done_ready,
    output configuration_error,
    output signed [15:0] wave_progress,
'''+ports('output')+'''
    output parameter_valid,
    input parameter_ready
);
    // 状态分别表示完成槽空闲，以及本帧已提交但尚未收到确认。
    localparam STATE_WAIT_EVENT_FRAME = 2'd0;
    localparam STATE_CALCULATE_FRAME = 2'd1;
    localparam STATE_MARK_PARAMETERS_DIRTY = 2'd2;
    localparam STATE_WAIT_COMPLETION_ACCEPT = 2'd3;
    // 余量范围为 -(steps-1)～+(steps-1)，包含符号位；
    // 候选结果再扩一位，保证达到阈值时的加法不溢出。
    localparam WAVE_PROGRESS_WIDTH = (WAVE_SELECT_STEPS > 1) ? $clog2(WAVE_SELECT_STEPS) + 1 : 2;
    wire [1:0] current_state;
    reg [1:0] next_state;
    reg signed [WAVE_PROGRESS_WIDTH-1:0] wave_progress_r;
    reg signed [WAVE_PROGRESS_WIDTH-1:0] wave_progress_next;
    reg signed [WAVE_PROGRESS_WIDTH:0] wave_sum;
    reg snapshot_valid_r;
    reg snapshot_dirty_r;
    wire bank_changed;
'''
    for n,w,d,a in FIELDS:
        s += f'    reg [{w-1}:0] {n}_r;\n    reg [{w-1}:0] {n}_next;\n    reg [{w-1}:0] {n}_snapshot_r;\n'
        s += f'    assign {n}{"[0]" if a else ""} = {n}_snapshot_r;\n'
    s += '''
    assign configuration_error = (WAVE_SELECT_STEPS < 1) || (WAVE_SELECT_STEPS > 32767);
    assign in_ready = rst_n && !configuration_error && (current_state == STATE_WAIT_EVENT_FRAME);
    assign frame_done_valid = rst_n && (current_state == STATE_WAIT_COMPLETION_ACCEPT);
    assign parameter_valid = rst_n && snapshot_valid_r;
    assign wave_progress = wave_progress_r;
    assign bank_changed = ''' + ' ||\n        '.join(f'({n}_previous != {n}_r)' for n,_,_,_ in FIELDS) + ''';

    fsm #(
        .W(2), .INITIAL_STATE(STATE_WAIT_EVENT_FRAME)
    ) fsm_u (
        .clk(clk_sys), .rst_n(rst_n), .stn(next_state), .stc(current_state)
    );
    always @(*)
    begin
        next_state = current_state;
        case (current_state)
            STATE_WAIT_EVENT_FRAME:
                if (in_valid && in_ready) next_state = STATE_CALCULATE_FRAME;
            STATE_CALCULATE_FRAME: next_state = STATE_MARK_PARAMETERS_DIRTY;
            STATE_MARK_PARAMETERS_DIRTY: next_state = STATE_WAIT_COMPLETION_ACCEPT;
            STATE_WAIT_COMPLETION_ACCEPT:
                if (frame_done_ready) next_state = STATE_WAIT_EVENT_FRAME;
            default: next_state = STATE_WAIT_EVENT_FRAME;
        endcase
    end

    // 使用 32 位有符号中间值，避免减法在限幅前发生无符号回绕。
    // 此处为小范围整数运算，不直接套用 Q 格式运算模块。
    function [31:0] adjust_value;
        input [31:0] value;
        input signed [1:0] delta;
        input [31:0] step;
        input [31:0] minimum;
        input [31:0] maximum;
        reg signed [32:0] candidate;
        begin
            candidate = $signed({1'b0, value});
            if (delta == 2'sd1) candidate = candidate + $signed({1'b0, step});
            else if (delta == -2'sd1) candidate = candidate - $signed({1'b0, step});
            if (candidate < $signed({1'b0, minimum})) adjust_value = minimum;
            else if (candidate > $signed({1'b0, maximum})) adjust_value = maximum;
            else adjust_value = candidate[31:0];
        end
    endfunction

    always @(*)
    begin
'''
    for n,w,d,a in FIELDS:
        s+=f'        {n}_next = {n}_r;\n'
    s+='''        wave_progress_next = clear_wave_progress ? '0 : wave_progress_r;
        wave_sum = $signed(wave_progress_next);
        if (edit_enable && !edit_target && ((mode == 2'd0) || (mode == 2'd1)))
        begin
            if (knob_pressed_event[0])
            begin
                wave_progress_next = '0;
                if (mode == 2'd0) wavetable_0_next = 4'd0;
                else wavetable_1_next = 4'd1;
            end
            else if ((knob_delta[0] == 2'sd1) || (knob_delta[0] == -2'sd1))
            begin
                wave_sum = wave_sum + $signed(knob_delta[0]);
                if ((((mode == 2'd0) ? wavetable_0_r : wavetable_1_r) == 4'd0 && wave_sum < 0) ||
                    (((mode == 2'd0) ? wavetable_0_r : wavetable_1_r) == 4'd3 && wave_sum > 0))
                    wave_progress_next = '0;
                else if (wave_sum >= WAVE_SELECT_STEPS)
                begin
                    if (mode == 2'd0) wavetable_0_next = wavetable_0_r + 4'd1;
                    else wavetable_1_next = wavetable_1_r + 4'd1;
                    wave_progress_next = '0;
                end
                else if (wave_sum <= -WAVE_SELECT_STEPS)
                begin
                    if (mode == 2'd0) wavetable_0_next = wavetable_0_r - 4'd1;
                    else wavetable_1_next = wavetable_1_r - 4'd1;
                    wave_progress_next = '0;
                end
                else wave_progress_next = wave_sum[WAVE_PROGRESS_WIDTH-1:0];
            end
'''
    mappings=[('master_percent',2,None,0,100,5,1),('interp_percent',1,0,0,100,5,1),('phase_degrees',1,1,0,359,5,1),('attack_ms',4,0,1,2000,10,1),('decay_ms',5,0,1,2000,10,1),('sustain_percent',6,0,0,100,5,1),('release_ms',7,0,0,5000,50,1)]
    mappings += [(n,4+i,1,0,100,5,1) for i,n in enumerate(['reverb_mix_percent','delay_mix_percent','distortion_mix_percent','chorus_mix_percent'])]
    widths={n:(w,d) for n,w,d,a in FIELDS}
    for n,k,m,lo,hi,coarse,fine in mappings:
        w,d=widths[n]
        if m is not None: s+=f"            if (mode == 2'd{m})\n            begin\n"
        pad='                ' if m is not None else '            '
        s+=f'{pad}if (knob_pressed_event[{k}]) {n}_next = {w}\'d{d};\n'
        s+=f'{pad}else {n}_next = {n}_adjusted[{w-1}:0];\n'
        if m is not None:s+='            end\n'
    s+='''        end
    end

    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            wave_progress_r <= '0;
            snapshot_valid_r <= 1'b0;
            snapshot_dirty_r <= 1'b1;
'''
    for n,w,d,a in FIELDS:s+=f"            {n}_r <= {w}'d{d};\n            {n}_snapshot_r <= {w}'d{d};\n"
    s+='''        end
        else
        begin
            // 发布时钟沿前的完整参数；同拍编辑会再次置位
            // 下方的更新标记，防止新编辑被旧快照覆盖而丢失。
            if (!snapshot_valid_r || parameter_ready)
            begin
                snapshot_valid_r <= snapshot_dirty_r;
                if (snapshot_dirty_r)
                begin
                    snapshot_dirty_r <= 1'b0;
'''
    for n,w,d,a in FIELDS:s+=f'                    {n}_snapshot_r <= {n}_r;\n'
    s+='''                end
            end
            if (current_state == STATE_CALCULATE_FRAME)
            begin
                wave_progress_r <= wave_progress_next;
'''
    for n,w,d,a in FIELDS:s+=f'                {n}_r <= {n}_next;\n'
    s+='''            end
            if ((current_state == STATE_MARK_PARAMETERS_DIRTY) && bank_changed)
                snapshot_dirty_r <= 1'b1;
        end
    end
endmodule
'''
    adjusted = '    // 先限幅到字段合法范围，再明确截取结果位宽。\n'
    for n,k,m,lo,hi,coarse,fine in mappings:
        adjusted += f'    wire [31:0] {n}_adjusted;\n'
        adjusted += f'    assign {n}_adjusted = adjust_value({n}_r, knob_delta[{k}],\n        fine_adjust ? 32\'d{fine} : 32\'d{coarse}, 32\'d{lo}, 32\'d{hi});\n'
    s=s.replace('    wire bank_changed;','    wire bank_changed;\n'+adjusted)
    # 先捕获事件，再更新参数存储，最后比较已寄存版本。
    # 将运算和完整参数更新检测拆成两个时钟周期。
    import re
    event_fields=[('knob_delta','signed [1:0]',' [7:0]'),('knob_pressed_event','[7:0]',''),
                  ('mode','[1:0]',''),('fine_adjust','',''),('edit_enable','',''),
                  ('edit_target','',''),('clear_wave_progress','','')]
    body_start=s.index('    // 状态分别表示完成槽空闲')
    header,body=s[:body_start],s[body_start:]
    for name,_,_ in event_fields:
        body=re.sub(r'\b'+name+r'\b',name+'_captured',body)
    captures='    // 冻结事务属性；握手后不再使用实时输入。\n'
    captures+='    integer capture_index;\n'
    for name,width,array in event_fields:captures+=f'    reg {width} {name}_captured{array};\n'
    for name,width,default,array in FIELDS:captures+=f'    reg [{width-1}:0] {name}_previous;\n'
    capture_reset=''
    capture_data=''
    for name,width,array in event_fields:
        if array:
            capture_reset+=f"            for (capture_index=0;capture_index<8;capture_index=capture_index+1) {name}_captured[capture_index] <= 2'sd0;\n"
            capture_data+=f'            for (capture_index=0;capture_index<8;capture_index=capture_index+1) {name}_captured[capture_index] <= {name}[capture_index];\n'
        else:
            capture_reset+=f"            {name}_captured <= '0;\n"
            capture_data+=f'            {name}_captured <= {name};\n'
    for name,width,default,array in FIELDS:
        capture_reset+=f"            {name}_previous <= {width}'d{default};\n"
        capture_data+=f'            {name}_previous <= {name}_r;\n'
    capture_process='''    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
'''+capture_reset+'''        end
        else if (in_valid && in_ready)
        begin
'''+capture_data+'''        end
    end
'''
    s=header+captures+body.replace('endmodule',capture_process+'endmodule')
    write('knob_parameter_controller',s)

def encoder():
    s='''/**
 * 把百分比、角度和毫秒换算成音频模块使用的参数编码。
 * SMP_TICK_FREQ: 采样率，Hz，范围 1000～209715；毫秒换算采用四舍五入。
 * attack_ticks/decay_ticks/release_ticks: 20 位采样周期数，相对 S1 改了单位和位宽。
 * wavetable_interp: UQ1.15，0～8000 表示 0～100%；其余比例用 UQ0.16。
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
'''+ports('input')+'''
    input in_valid,
    output in_ready,
'''
    for n,w,a,e in ENCODED:s+=f'    output [{w-1}:0] {"encoded_" if n in ("wavetable_0","wavetable_1") else ""}{n}'+(' [0:0]' if a else '')+',\n'
    s+='''    output out_valid,
    input out_ready
);
    localparam STATE_WAIT_PARAMETER_SNAPSHOT = 2'd0;
    localparam STATE_CONVERT_SNAPSHOT = 2'd1;
    localparam STATE_WAIT_ENCODED_ACCEPT = 2'd2;
    wire [1:0] current_state;
    reg [1:0] next_state;
'''
    for n,w,d,a in FIELDS:s+=f'    reg [{w-1}:0] {n}_captured;\n'
    for n,w,a,e in ENCODED:
        s+=f'    reg [{w-1}:0] {n}_encoded_r;\n'
        s+=f'    assign {"encoded_" if n in ("wavetable_0","wavetable_1") else ""}{n}{"[0]" if a else ""} = {n}_encoded_r;\n'
    s+='''
    assign in_ready = rst_n && (current_state == STATE_WAIT_PARAMETER_SNAPSHOT);
    assign out_valid = rst_n && (current_state == STATE_WAIT_ENCODED_ACCEPT);
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
                if (in_valid) next_state = STATE_CONVERT_SNAPSHOT;
            STATE_CONVERT_SNAPSHOT: next_state = STATE_WAIT_ENCODED_ACCEPT;
            STATE_WAIT_ENCODED_ACCEPT:
                if (out_ready) next_state = STATE_WAIT_PARAMETER_SNAPSHOT;
            default: next_state = STATE_WAIT_PARAMETER_SNAPSHOT;
        endcase
    end

    // 仅使用常量除数，精确四舍五入，不使用迭代除法。
    // 整合前仍必须检查综合后的资源和时序开销。
    function [15:0] encode_percent;
        input [6:0] percent;
        reg [31:0] scaled;
        begin
            scaled = (32'd65536 * percent + 32'd50) / 32'd100;
            encode_percent = (scaled > 32'd65535) ? 16'hFFFF : scaled[15:0];
        end
    endfunction
    function [15:0] encode_interp;
        input [6:0] percent;
        reg [31:0] scaled;
        begin
            scaled = (32'd32768 * percent + 32'd50) / 32'd100;
            encode_interp = scaled[15:0];
        end
    endfunction
    function [15:0] encode_phase;
        input [8:0] degrees;
        reg [31:0] scaled;
        begin
            scaled = (32'd65536 * degrees + 32'd180) / 32'd360;
            encode_phase = scaled[15:0];
        end
    endfunction
    function [31:0] encode_time;
        input [12:0] milliseconds;
        reg [63:0] scaled;
        begin
            // 48 kHz 下每毫秒恰好对应 48 个采样周期。
            if ((SMP_TICK_FREQ % 1000) == 0)
                scaled = {51'd0, milliseconds} * (SMP_TICK_FREQ / 1000);
            else scaled = ({51'd0, milliseconds} * SMP_TICK_FREQ + 64'd500) / 64'd1000;
            encode_time = scaled[31:0];
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
'''
    for n,w,d,a in FIELDS:s+=f'            {n}_captured <= {w}\'d0;\n'
    for n,w,a,e in ENCODED:s+=f'            {n}_encoded_r <= {w}\'d0;\n'
    s+='''        end
        else
        begin
            if (in_valid && in_ready)
            begin
'''
    for n,w,d,a in FIELDS:s+=f'                {n}_captured <= {n}{"[0]" if a else ""};\n'
    s+='''            end
            if (current_state == STATE_CONVERT_SNAPSHOT)
            begin
'''
    for n,w,a,e in ENCODED:
        for fn,fw,d,fa in FIELDS:e=e.replace(fn+('[0]' if fa else ''),fn+'_captured')
        s+=f'                {n}_encoded_r <= {e};\n'
    s+='''            end
        end
    end
endmodule
'''
    # 对有限输入域使用精确查表，避免高云将
    # phase*65536/360 综合为长除法路径；查找表由独立
    # 算术参考模型穷举验证，不近似舍入规则。
    def table_function(name, arg, width, values, fallback):
        lines=[f'    function [15:0] {name};',f'        input [{width-1}:0] {arg};',
               '        begin',f'            case ({arg})']
        lines += [f"                {width}'d{i}: {name} = 16'd{value};" for i,value in enumerate(values)]
        lines += [f"                default: {name} = 16'd{fallback};",'            endcase','        end','    endfunction']
        return '\n'.join(lines)+'\n'
    tables = '    // 对有限合法输入域进行精确组合查表。\n'
    tables += table_function('encode_percent','percent',7,[min(65535,(p*65536+50)//100) for p in range(101)],65535)
    tables += table_function('encode_interp','percent',7,[(p*32768+50)//100 for p in range(101)],0)
    tables += table_function('encode_phase','degrees',9,[(d*65536+180)//360 for d in range(360)],0)
    first=s.index('    // 仅使用常量除数')
    last=s.index('    function [31:0] encode_time;')
    s=s[:first]+tables+s[last:]
    from time_conversion_rtl import add_time_pipeline
    write('ui_parameter_encoder',add_time_pipeline(s))

if __name__ == '__main__':
    controller()
    encoder()
