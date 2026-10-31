"""生成按 32 进制拆分的精确毫秒转换表，避免运行时长组合除法。"""

import sys
sys.dont_write_bytecode = True

def add_time_pipeline(source):
    # x=32h+l；各部分独立存商和余数，最后相加并仅进行一次四舍五入。
    source = source.replace('STATE_CONVERT_SNAPSHOT = 2\'d1;',
        'STATE_READ_TIME_PARTS = 2\'d1;\n    localparam STATE_CONVERT_SNAPSHOT = 2\'d2;')
    source = source.replace('STATE_WAIT_ENCODED_ACCEPT = 2\'d2;', 'STATE_WAIT_ENCODED_ACCEPT = 2\'d3;')
    source = source.replace('if (in_valid) next_state = STATE_CONVERT_SNAPSHOT;',
        'if (in_valid) next_state = STATE_READ_TIME_PARTS;\n            STATE_READ_TIME_PARTS: next_state = STATE_CONVERT_SNAPSHOT;')
    names = ('attack', 'decay', 'release')
    declarations = '''    // 参数单位 Hz；查表常量在综合展开时计算，无运行时除法。
    // 每个表项为 {32 位商, 10 位余数}，对 0～8191 ms 精确分解；输出超过 20 位时饱和，禁止回绕。
    localparam [63:0] TIME_SAMPLE_RATE_HZ = SMP_TICK_FREQ;
'''
    for name in names:
        declarations += f'''    reg [41:0] {name}_high_part_r;
    reg [41:0] {name}_low_part_r;
    // 余数之和加 500 最大为 2498，必须使用 12 位，不能截成 11 位。
    wire [11:0] {name}_rounding_sum;
    wire [31:0] {name}_sample_count;
    assign {name}_sample_count = {name}_high_part_r[41:10] + {name}_low_part_r[41:10] +
        (({name}_rounding_sum >= 12'd2000) ? 32'd2 :
        (({name}_rounding_sum >= 12'd1000) ? 32'd1 : 32'd0));
    assign {name}_rounding_sum = {{2'b00,{name}_high_part_r[9:0]}} +
        {{2'b00,{name}_low_part_r[9:0]}} + 12'd500;
'''
    source = source.replace('    assign in_ready =', declarations+'\n    assign in_ready =', 1)
    first = source.index('    function [31:0] encode_time;')
    last = source.index('    endfunction', first) + len('    endfunction')
    table = ''
    for part, width, multiplier in (('high',8,32),('low',5,1)):
        table += f'''    function [41:0] time_{part}_parts;
        input [{width-1}:0] index;
        begin
            case (index)
'''
        for value in range(1 << width):
            product = f"64'd{value*multiplier} * TIME_SAMPLE_RATE_HZ"
            table += (f"                {width}'d{value}: time_{part}_parts = "
                f"(((({product}) / 64'd1000) << 10) | (({product}) % 64'd1000));\n")
        table += f'''                default: time_{part}_parts = 42'd0;
            endcase
        end
    endfunction
'''
    source = source[:first]+table+source[last:]
    reset = ''.join(f"            {n}_high_part_r <= 42'd0;\n            {n}_low_part_r <= 42'd0;\n" for n in names)
    anchor = "            wavetable_0_captured <= 4'd0;"
    source = source.replace(anchor, reset+anchor)
    read = '''            // 第一转换拍读取商余数表；第二拍合并，所有字段一起发布。
            if (current_state == STATE_READ_TIME_PARTS)
            begin
'''
    for n in names:
        high = f'{n}_ms_captured[12:5]' if n=='release' else f"{{2'd0,{n}_ms_captured[10:5]}}"
        read += f'                {n}_high_part_r <= time_high_parts({high});\n'
        read += f'                {n}_low_part_r <= time_low_parts({n}_ms_captured[4:0]);\n'
        source = source.replace(f'encode_time({n}_ms_captured)',
            f"({n}_sample_count > 32'd1048575) ? 20'hFFFFF : {n}_sample_count[19:0]")
    read += '            end\n'
    source = source.replace('            if (current_state == STATE_CONVERT_SNAPSHOT)',read+'            if (current_state == STATE_CONVERT_SNAPSHOT)')
    source = source.replace(');\n    localparam STATE_WAIT',
        ') /* synthesis syn_romstyle = "logic" */;\n'
        '    // 小型查表用逻辑实现，避免自动推断块 ROM 引入本工程的时钟脉宽违例。\n'
        '    // 仅限定本模块，不改变正式 PLL、数值算法、两拍转换或 valid/ready 时序。\n'
        '    localparam STATE_WAIT', 1)
    return source
