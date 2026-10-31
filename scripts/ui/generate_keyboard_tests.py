"""独立参考模型：无限增长触发序号排序，区别于 RTL 的有界相对年龄。"""

import sys
sys.dont_write_bytecode = True
from pathlib import Path
import random

# 生成结果只保存在 ai_workspace，审核后再决定是否替换正式文件。
REPO = Path(__file__).resolve().parents[2]
ROOT = REPO / 'ai_workspace/ui_generated'
for subdir in ('src/ui', 'sim/tb/ui', 'sim/assets', 'sim/assets/system', 'results'):
    (ROOT / subdir).mkdir(parents=True, exist_ok=True)
ASSETS = ROOT / 'sim/assets'
ASSETS.mkdir(parents=True, exist_ok=True)
CONFIGS = [(1, 1), (3, 1), (3, 2), (24, 3), (24, 32)]
for keys, voices in CONFIGS:
    rng = random.Random(9321 + keys * 100 + voices)
    owner = [0] * voices
    allocated = [False] * voices
    held = [False] * voices
    age = [-v - 1 for v in range(voices)]
    low = [False] * voices
    high = [False] * voices
    completed = [False] * voices
    sequence = 0
    previous = 0
    rows = []
    mask = (1 << keys) - 1
    directed = [0, 1, 1, 1, 0, 1, mask, mask, mask & ~1, 0, mask, 0]
    for frame in range(612):
        states = directed[frame] if frame < len(directed) else (
            previous ^ (1 << rng.randrange(keys)) if frame % 3 else rng.getrandbits(keys))
        busy = 0 if frame < 6 else rng.getrandbits(voices)
        for v in range(voices):
            if allocated[v]:
                if not (busy >> v) & 1 and not high[v]:
                    low[v] = True
                if (busy >> v) & 1 and low[v]:
                    high[v] = True
                if not (busy >> v) & 1 and high[v]:
                    completed[v] = True
        presses = states & ~previous
        releases = previous & ~states
        on = off = 0
        for v in range(voices):
            if allocated[v]:
                if not held[v] and completed[v]:
                    allocated[v] = False
                if held[v] and (releases >> owner[v]) & 1:
                    held[v] = False
                    off |= 1 << v
        for key in range(keys):
            if not (presses >> key) & 1:
                continue
            free = [v for v in range(voices) if not allocated[v] and not (busy >> v) & 1]
            tails = [v for v in range(voices) if allocated[v] and not held[v]]
            v = min(free) if free else min(tails or list(range(voices)), key=lambda v: (age[v], v))
            allocated[v] = held[v] = True
            owner[v] = key
            sequence += 1
            age[v] = sequence
            low[v] = high[v] = completed[v] = False
            on |= 1 << v
            off &= ~(1 << v)
        occupied = sum(int(x) << v for v, x in enumerate(allocated))
        held_mask = sum(int(x) << v for v, x in enumerate(held))
        rows.append(' '.join(f'{x:x}' for x in [states, busy, on, off, occupied, held_mask, *owner]))
        for v in range(voices):
            if (on >> v) & 1:
                low[v] = not ((busy >> v) & 1)
                high[v] = completed[v] = False
        previous = states
    (ASSETS / f'allocator_{keys}_{voices}.txt').write_text('\n'.join(rows) + '\n', encoding='ascii')

for module in ('keyboard_voice_allocator', 'keyboard_event_handler'):
    tb = '''/**
 * 键盘分配自检：独立时间序号模型，612 帧，少/多声部、尾音优先、旧键隔离、
 * 无 busy 确认的本地预留、延迟 busy、持续按住、同帧先松后按、背压及复位取消。
 * 压力包装另检查同帧保存；无效外部变化不得污染冻结结果。
 */
`timescale 1ns/1ps
module MODULE_tb;
    parameter KEY_NUM = 24;
    parameter MAX_POLYPHONY = 32;
    localparam KEY_ID_WIDTH = (KEY_NUM > 1) ? $clog2(KEY_NUM) : 1;
    reg clk_sys = 1'b0;
    always #5 clk_sys = ~clk_sys;
    reg rst_n = 1'b0;
    reg [KEY_NUM-1:0] key_states = '0;
    reg [KEY_NUM-1:0] previous_states = '0;
    reg [KEY_NUM-1:0] press_event = '0;
    reg [KEY_NUM-1:0] release_event = '0;
    reg [15:0] key_velocity [KEY_NUM-1:0];
    wire [15:0] frame_velocity [KEY_NUM-1:0];
    reg [MAX_POLYPHONY-1:0] note_busy = '0;
    reg in_valid = 1'b0;
    wire in_ready;
    wire out_valid;
    reg out_ready = 1'b0;
    wire [MAX_POLYPHONY-1:0] note_on, note_off, occupied, held;
    wire [KEY_ID_WIDTH-1:0] key_id [MAX_POLYPHONY-1:0];
    reg [MAX_POLYPHONY-1:0] expected_on, expected_off, expected_occupied, expected_held;
    reg [KEY_ID_WIDTH-1:0] expected_id [MAX_POLYPHONY-1:0];
    integer source, scan_count, frame, voice, key_index, cycles, stall;
    reg [4095:0] assets;
    reg [4095:0] filename;
    MODULE #(.KEY_NUM(KEY_NUM), .MAX_POLYPHONY(MAX_POLYPHONY)) MODULE_u (
        .clk_sys(clk_sys), .rst_n(rst_n), EXTRA_PORTS
        .note_busy(note_busy), .in_valid(in_valid), .in_ready(in_ready),
        .note_on(note_on), .note_off(note_off), .key_id(key_id), .occupied(occupied), .held(held),
        .out_valid(out_valid), .out_ready(out_ready)
    );
    task check_result;
        begin
            if (!out_valid || note_on !== expected_on || note_off !== expected_off ||
                occupied !== expected_occupied || held !== expected_held)
                $fatal(1, "帧 %0d 位图错误 on=%h/%h off=%h/%h occ=%h/%h held=%h/%h", frame,
                    note_on, expected_on, note_off, expected_off, occupied, expected_occupied, held, expected_held);
            for (voice = 0; voice < MAX_POLYPHONY; voice = voice + 1)
                if (key_id[voice] !== expected_id[voice]) $fatal(1, "帧 %0d 声部 %0d 归属错误", frame, voice);
            PRESSURE_CHECK
        end
    endtask
    initial
    begin
        if (!$value$plusargs("ASSETS=%s", assets)) $fatal(1, "缺少向量路径");
        $sformat(filename, "%0s/allocator_%0d_%0d.txt", assets, KEY_NUM, MAX_POLYPHONY);
        source = $fopen(filename, "r");
        if (!source) $fatal(1, "无法读取参考向量");
        repeat (3) @(negedge clk_sys);
        rst_n = 1'b1;
        for (frame = 0; frame < 612; frame = frame + 1)
        begin
            @(negedge clk_sys);
            scan_count = $fscanf(source, "%h %h %h %h %h %h", key_states, note_busy,
                expected_on, expected_off, expected_occupied, expected_held);
            if (scan_count != 6) $fatal(1, "参考帧不完整");
            for (voice = 0; voice < MAX_POLYPHONY; voice = voice + 1)
                scan_count = $fscanf(source, "%h", expected_id[voice]);
            press_event = key_states & ~previous_states;
            release_event = ~key_states & previous_states;
            previous_states = key_states;
            for (key_index = 0; key_index < KEY_NUM; key_index = key_index + 1)
                key_velocity[key_index] = (frame * 177 + key_index * 2039) & 65535;
            repeat (4) @(negedge clk_sys);
            in_valid = 1'b1;
            while (!in_ready) @(negedge clk_sys);
            @(negedge clk_sys);
            in_valid = 1'b0;
            key_states = ~key_states;
            for (key_index = 0; key_index < KEY_NUM; key_index = key_index + 1)
                key_velocity[key_index] = 16'hffff;
            cycles = 0;
            while (!out_valid)
            begin
                @(negedge clk_sys);
                cycles = cycles + 1;
                // IF-KEYBOARD-05：每个新按键增加一次末候选排空，原参考结果不变。
                if (cycles > MAX_POLYPHONY + KEY_NUM * (MAX_POLYPHONY + 3) + 12)
                    $fatal(1, "事件处理超出周期预算");
            end
            for (stall = 0; stall < (frame % 17) + 1; stall = stall + 1)
            begin
                check_result;
                if (in_ready) $fatal(1, "事务未交付就重新接收");
                @(negedge clk_sys);
            end
            out_ready = 1'b1;
            @(negedge clk_sys);
            out_ready = 1'b0;
            if (out_valid) $fatal(1, "重复交付");
        end
        $fclose(source);
        // 制造未交付结果后异步复位，取消载荷并恢复首次按键语义。
        in_valid = 1'b1;
        key_states = '1;
        press_event = '1;
        release_event = '0;
        while (!in_ready) @(negedge clk_sys);
        @(negedge clk_sys);
        in_valid = 1'b0;
        while (!out_valid) @(negedge clk_sys);
        #2 rst_n = 1'b0;
        #1;
        if (out_valid || in_ready || note_on || note_off || occupied) $fatal(1, "复位没有取消事务");
        $display("MODULE_PASS keys=%0d voices=%0d frames=612", KEY_NUM, MAX_POLYPHONY);
        $finish;
    end
    initial
    begin
        #20000000;
        $fatal(1, "看门狗超时");
    end
endmodule
'''
    extra = '.press_event(press_event), .release_event(release_event),' if module.endswith('allocator') else (
        ".scan_tick_up(1'b0), .key_states(key_states), .key_velocity(key_velocity), .frame_velocity(frame_velocity),")
    check = '' if module.endswith('allocator') else '''for (key_index = 0; key_index < KEY_NUM; key_index = key_index + 1)
                if (frame_velocity[key_index] !== ((frame * 177 + key_index * 2039) & 65535))
                    $fatal(1, "同帧压力丢失");'''
    tb = tb.replace('MODULE', module).replace('EXTRA_PORTS', extra).replace('PRESSURE_CHECK', check)
    (ROOT / f'sim/tb/ui/{module}_tb.vt').write_text(tb, encoding='utf-8')
