"""公开 UI 的独立事务参考模型；不导入 RTL 生成器，不读取 DUT 状态。

每行是一段 2048 系统周期，末沿为采样 tick。正常输入放在前 900 周期内，
给最坏 24 键分配留足处理时间；每四段最多一帧，模拟 12 kHz 扫描。
参考模型用无限增长的触发序号选声部、数学公式计算频率和定点编码。
busy 是明确的测试接收器协议：起音确认先低后高，松开后延迟结束尾音。
这不是实际音频包络，也不声称覆盖所有内部状态和任意到达相位。
"""

import sys
sys.dont_write_bytecode = True
from pathlib import Path
import json
import math
import random
from collections import Counter

# 生成结果只保存在 ai_workspace，审核后再决定是否替换正式文件。
REPO = Path(__file__).resolve().parents[2]
ROOT = REPO / 'ai_workspace/ui_generated'
for subdir in ('src/ui', 'sim/tb/ui', 'sim/assets', 'sim/assets/system', 'results'):
    (ROOT / subdir).mkdir(parents=True, exist_ok=True)
OUT = ROOT / 'sim/assets/system'
DEFAULT = [0, 1, 0, 0, 5, 150, 70, 200, 30, 0, 0, 0, 0]
WIDTHS = [4, 4, 16, 16, 20, 20, 16, 20, 16, 16, 16, 16, 16]
FREQUENCY = [math.floor(440 * 2 ** ((k - 9) / 12) * 65536 + 0.5) for k in range(24)]


class Reference:
    def __init__(self, coverage):
        self.coverage = coverage
        self.values = DEFAULT.copy()
        self.mode = 0
        self.menu = False
        self.last_button = self.last_knob = None
        self.progress = 0
        self.keys = 0
        self.pressure = [0] * 24
        self.owner = [0] * 32
        self.allocated = [False] * 32
        self.held = [False] * 32
        self.delivered = [False] * 32
        self.low = [False] * 32
        self.high = [False] * 32
        self.completed = [False] * 32
        self.age = [-v - 1 for v in range(32)]
        self.sequence = 0
        self.velocity = [0] * 32
        self.on = self.off = 0

    def observe_busy(self, busy):
        for v in range(32):
            if self.allocated[v] and self.delivered[v]:
                if not (busy >> v) & 1:
                    if self.high[v]:
                        self.completed[v] = True
                    else:
                        self.low[v] = True
                elif self.low[v]:
                    self.high[v] = True

    def accept_audio(self, on, busy):
        for v in range(32):
            if (on >> v) & 1:
                self.delivered[v] = True
                self.low[v] = not ((busy >> v) & 1)
                self.high[v] = self.completed[v] = False

    def input_frame(self, keys, buttons, states, directions, pressed, pressure, busy):
        presses, releases = keys & ~self.keys, self.keys & ~keys
        self.keys = keys
        self.pressure = pressure.copy()
        self.on = self.off = 0
        for v in range(32):
            if self.allocated[v]:
                if not self.held[v] and self.completed[v]:
                    self.allocated[v] = False
                    self.coverage['reclaimed_voices'] += 1
                if self.held[v] and (releases >> self.owner[v]) & 1:
                    self.held[v] = False
                    self.off |= 1 << v
        for key in range(24):
            if not (presses >> key) & 1:
                continue
            free = [v for v in range(32) if not self.allocated[v] and not (busy >> v) & 1]
            tails = [v for v in range(32) if self.allocated[v] and not self.held[v]]
            if free:
                v = min(free)
            else:
                v = min(tails or list(range(32)), key=lambda x: (self.age[x], x))
                self.coverage['tail_steals' if tails else 'held_steals'] += 1
            self.owner[v] = key
            self.sequence += 1
            self.age[v] = self.sequence
            self.allocated[v] = self.held[v] = True
            self.delivered[v] = self.low[v] = self.high[v] = self.completed[v] = False
            self.on |= 1 << v
            self.off &= ~(1 << v)
        count = keys.bit_count()
        self.coverage['max_held_keys'] = max(self.coverage['max_held_keys'], count)
        self.coverage['max_allocated'] = max(self.coverage['max_allocated'], sum(self.allocated))
        if count in (1, 5, 8, 24):
            self.coverage[f'chord_{count}_frames'] += 1

        button_edges = 0 if self.last_button is None else buttons & ~self.last_button
        knob_edges = 0 if self.last_knob is None else pressed & ~self.last_knob
        self.last_button, self.last_knob = buttons, pressed
        clear = False
        if self.menu:
            if button_edges & 8:
                self.menu, clear = False, True
        elif button_edges & 1:
            self.menu, clear = True, True
        elif button_edges & 2:
            self.mode ^= 1
            clear = True
            self.coverage['mode_changes'] += 1
        if clear:
            self.progress = 0
        if self.menu:
            self.coverage['menu_frames'] += 1
            return
        fine = bool(buttons & 8)
        self.coverage['fine_frames' if fine else 'coarse_frames'] += 1
        delta = [(1 if directions & (1 << k) else -1) if states & (1 << k) else 0 for k in range(8)]
        if knob_edges & 1:
            self.values[self.mode] = DEFAULT[self.mode]
            self.progress = 0
        elif delta[0]:
            self.progress += delta[0]
            if (self.values[self.mode] == 0 and self.progress < 0) or (self.values[self.mode] == 3 and self.progress > 0):
                self.progress = 0
            elif abs(self.progress) >= 4:
                self.values[self.mode] += 1 if self.progress > 0 else -1
                self.progress = 0
                self.coverage['wave_changes'] += 1
        mapping = [(8, 2, 0, 100, 5)]
        if self.mode == 0:
            mapping += [(2, 1, 0, 100, 5), (4, 4, 1, 2000, 10), (5, 5, 1, 2000, 10), (6, 6, 0, 100, 5), (7, 7, 0, 5000, 50)]
        else:
            mapping += [(3, 1, 0, 359, 5)] + [(9 + i, 4 + i, 0, 100, 5) for i in range(4)]
        for field, knob, lower, upper, coarse in mapping:
            if knob_edges & (1 << knob):
                self.values[field] = DEFAULT[field]
                self.coverage['parameter_resets'] += 1
                if field == 3:
                    self.coverage['phase_resets'] += 1
            else:
                self.values[field] = min(upper, max(lower, self.values[field] + delta[knob] * (1 if fine else coarse)))
        if self.values[7] == 0:
            self.coverage['release_zero_frames'] += 1
        if self.values[2] == 100:
            self.coverage['interpolation_one_frames'] += 1

    def sample(self):
        p = self.values
        percent = lambda value: min(65535, (value * 65536 + 50) // 100)
        fields = [p[0], p[1], (p[2] * 32768 + 50) // 100, (p[3] * 65536 + 180) // 360,
                  p[4] * 48, p[5] * 48, percent(p[6]), p[7] * 48] + [percent(v) for v in p[8:]]
        packed = 0
        for value, width in zip(fields, WIDTHS):
            assert 0 <= value < (1 << width)
            packed = (packed << width) | value
        on, off = self.on, self.off
        packed |= on << 196 | off << 228
        for v in range(32):
            target = max(3277, self.pressure[self.owner[v]])
            old = self.velocity[v]
            if not self.allocated[v]:
                self.velocity[v] = 0
            elif (on >> v) & 1:
                self.velocity[v] = target
            elif self.held[v]:
                self.velocity[v] += min(274, max(-274, target - self.velocity[v]))
                if self.velocity[v] != old:
                    self.coverage['slew_samples'] += 1
            else:
                self.coverage['frozen_tail_samples'] += 1
            frequency = FREQUENCY[self.owner[v]] if self.allocated[v] else 0
            packed |= frequency << (260 + 48 * v)
            packed |= self.velocity[v] << (292 + 48 * v)
        self.on = self.off = 0
        self.coverage['note_on_events'] += on.bit_count()
        self.coverage['note_off_events'] += off.bit_count()
        return packed, on, off


def scenarios(seed):
    rng = random.Random(seed)
    rows = []
    keys, buttons, pressure = 0, 0, [20000 + k * 701 for k in range(24)]

    def idle(count=1, label='hold', **kwargs):
        for _ in range(count):
            rows.append(dict(label=label, **kwargs))

    def frame(label, new_keys=None, b=0, states=0, dirs=255, pressed=0, level=None):
        nonlocal keys, buttons, pressure
        if new_keys is not None:
            keys = new_keys
        buttons = b
        if level is not None:
            pressure = ([level] * 24) if isinstance(level, int) else level.copy()
        rows.append(dict(label=label, frame=(keys, buttons, states, dirs, pressed, pressure.copy()), phase=rng.randrange(128, 901)))
        idle(3)

    idle(label='startup_reset', reset=True)
    frame('baseline', 0)
    frame('single_a4', 1 << 9, level=0)
    frame('pressure_rise', level=65535)
    idle(245, 'pressure_rise_settle')
    frame('pressure_fall', level=0)
    idle(245, 'pressure_fall_settle')
    frame('single_release', 0)
    frame('five_note_chord', 0x000295, level=[(k * 3503) & 65535 for k in range(24)])
    frame('adsr_coarse', states=0xf0)
    frame('adsr_fine_same_frame_b4', b=8, states=0xf0)
    frame('adsr_fine_held_b4', b=8, states=0xf0, dirs=0)
    frame('adsr_back_to_coarse', states=0xf0)
    frame('mode_and_phase_same_frame', b=2, states=2)
    frame('phase_fine', b=8, states=2)
    frame('phase_reset_beats_rotation', states=2, pressed=2)
    frame('phase_held_not_repeat', states=2, pressed=2)
    frame('phase_release', pressed=0)
    for _ in range(16):
        frame('right_wave_steps', states=1)
    for _ in range(5):
        frame('right_wave_reverse', states=1, dirs=0)
    frame('mix_coarse', states=0xf4)
    frame('mix_fine', b=8, states=0xf4)
    frame('all_defaults_mode1', pressed=255, states=255)
    frame('mode0', b=2)
    for _ in range(21):
        frame('left_wave_interpolation', states=3)
    for _ in range(7):
        frame('release_zero', states=128, dirs=0)
    frame('menu_disable_edit', b=1, states=255)
    frame('menu_stay', b=2, states=255)
    frame('menu_exit_fine', b=8, states=0xf0)
    frame('eight_note_chord', 255)
    frame('24_note_chord', 0xffffff)
    frame('24_release_long_tail', 0)
    frame('32_slots_tail_steal', 0xffffff)
    frame('interleaved_release', 0xaaaaaa)
    frame('interleaved_retrigger', 0xffffff)
    frame('all_release', 0)
    idle(140, 'tail_feedback_wait')
    frame('reclaim_finished_tails', 0)
    for i in range(64):
        frame('random_mixed', rng.getrandbits(24), b=rng.choice([0, 0, 2, 8]),
              states=rng.getrandbits(8), dirs=rng.getrandbits(8),
              pressed=rng.getrandbits(8) if i % 9 == 0 else 0,
              level=[rng.randrange(65536) for _ in range(24)])
    # 不发送新输入时跨两个 tick 阻塞；旧样本不得改写或重复交付。
    idle(label='overrun_start', ready=2048)
    idle(2, 'overrun_wait', ready=2048)
    idle(label='consume_on_tick', ready=2047)
    idle(2, 'overrun_sticky')
    # 挂起输出时复位取消；之后重新建立按钮基线并演奏和弦。
    idle(label='reset_pending_start', ready=2048)
    idle(label='reset_pending', reset=True)
    frame('reset_baseline', 0, level=3277)
    frame('reset_five_note_chord', 0x295)
    frame('reset_release', 0)
    idle(8, 'final_hold')
    idle(label='drain', tick=False)
    return rows


def generate(seed):
    rng = random.Random(seed ^ 0x5a5a)
    coverage = Counter()
    model = Reference(coverage)
    pending = None
    busy = 0
    generation = [0] * 32
    feedback = []
    overrun = False
    lines, descriptions = [], []
    for index, row in enumerate(scenarios(seed)):
        reset = row.get('reset', False)
        ready = row.get('ready', rng.choice([0, 0, 0, 20, 71]))
        if reset:
            if pending is not None:
                coverage['reset_cancelled'] += 1
            model, pending, busy = Reference(coverage), None, 0
            feedback.clear()
            generation = [0] * 32
            overrun = False
        for when, voice, gen, value in feedback:
            if when == index and generation[voice] == gen:
                busy = (busy | (1 << voice)) if value else (busy & ~(1 << voice))
        model.observe_busy(busy)
        if pending is not None and ready < 2048:
            _, on, off = pending
            model.accept_audio(on, busy)
            for v in range(32):
                if (on >> v) & 1:
                    generation[v] += 1
                    feedback.extend([(index + 1, v, generation[v], 0), (index + 2, v, generation[v], 1)])
                elif (off >> v) & 1:
                    feedback.append((index + 128, v, generation[v], 0))
            pending = None
            coverage['accepted_samples'] += 1
        frame = row.get('frame')
        if frame:
            assert pending is None, '本场景的新输入必须在旧结果接收后发送'
            model.input_frame(*frame, busy)
            coverage['input_frames'] += 1
        tick = row.get('tick', True)
        new_sample = int(tick and pending is None)
        payload = 0
        if new_sample:
            pending = model.sample()
            payload = pending[0]
            coverage['created_samples'] += 1
        elif tick:
            overrun = True
            coverage['skipped_ticks'] += 1
        keys, buttons, states, directions, pressed, pressure = frame or (0, 0, 0, 0, 0, [0] * 24)
        values = [index, int(reset), row.get('phase', 2048), ready, keys, buttons, states, directions, pressed, busy,
                  *pressure, int(tick), new_sample, int(overrun)]
        lines.append(' '.join(f'{v:x}' for v in values) + f' {payload:0449x}')
        descriptions.append({'slot': index, 'label': row['label'], 'input': bool(frame), 'new_sample': bool(new_sample)})
    assert pending is None
    for key in ('chord_5_frames', 'chord_8_frames', 'chord_24_frames', 'tail_steals', 'reclaimed_voices',
                'slew_samples', 'phase_resets', 'wave_changes', 'fine_frames', 'release_zero_frames',
                'interpolation_one_frames', 'reset_cancelled', 'skipped_ticks'):
        assert coverage[key] > 0, f'遗漏场景 {key}'
    assert coverage['max_allocated'] == 32
    header = f"{len(lines)} {coverage['input_frames']} {coverage['accepted_samples']} {coverage['reset_cancelled']} {coverage['skipped_ticks']}"
    (OUT / f'system_{seed}.txt').write_text(header + '\n' + '\n'.join(lines) + '\n', encoding='ascii')
    (OUT / f'system_{seed}.json').write_text(json.dumps({'seed': seed, 'coverage': coverage, 'slots': descriptions}, ensure_ascii=False, indent=2), encoding='utf-8')
    return dict(seed=seed, slots=len(lines), **coverage)


if __name__ == '__main__':
    OUT.mkdir(parents=True, exist_ok=True)
    print(json.dumps([generate(seed) for seed in (1018, 2026, 9321)], ensure_ascii=False, indent=2))
