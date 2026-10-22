"""以整数物理单位实现独立行为参考模型。

生成确定性输入／输出向量进行 RTL 黑盒测试；不读取
RTL 实现或仿真器内部寄存器；1／2／4 仅为测试所用
波形步数阈值，生成器和 RTL 都不代替产品确定该值。
"""

import sys
sys.dont_write_bytecode = True
import random
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
FIELDS = [('wavetable_0', 4, 0, True), ('wavetable_1', 4, 1, True), ('interp_percent', 7, 0, True), ('phase_degrees', 9, 0, True), ('attack_ms', 11, 5, True), ('decay_ms', 11, 150, True), ('sustain_percent', 7, 70, True), ('release_ms', 13, 200, True), ('master_percent', 7, 30, False), ('reverb', 7, 0, False), ('delay', 7, 0, False), ('distortion', 7, 0, False), ('chorus', 7, 0, False)]

ASSETS = ROOT / 'assets/ui/test_vectors/control'
ASSETS.mkdir(parents=True, exist_ok=True)
DEFAULTS = [x[2] for x in FIELDS]

class Bank:
    def __init__(self, steps):
        self.values = DEFAULTS.copy()
        self.progress = 0
        self.steps = steps

    def apply(self, mode, fine, enabled, target, clear, pressed, delta):
        if clear:
            self.progress = 0
        if not enabled or target or mode not in (0, 1):
            return
        if pressed & 1:
            self.values[mode] = DEFAULTS[mode]
            self.progress = 0
        elif delta[0] in (-1, 1):
            self.progress += delta[0]
            if (self.values[mode] == 0 and self.progress < 0) or (self.values[mode] == 3 and self.progress > 0):
                self.progress = 0
            elif abs(self.progress) >= self.steps:
                self.values[mode] += 1 if self.progress > 0 else -1
                self.progress = 0
        mapping = [(8, 2, 0, 100, 5)]
        if mode == 0:
            mapping += [(2,1,0,100,5), (4,4,1,2000,10), (5,5,1,2000,10), (6,6,0,100,5), (7,7,0,5000,50)]
        else:
            mapping += [(3,1,0,359,5)] + [(9+i,4+i,0,100,5) for i in range(4)]
        for field, knob, low, high, coarse in mapping:
            if pressed & (1 << knob):
                self.values[field] = DEFAULTS[field]
            elif delta[knob] in (-1, 1):
                self.values[field] = max(low, min(high, self.values[field] + delta[knob]*(1 if fine else coarse)))

def encode(v, freq):
    percent = lambda p: min(65535, (p*65536+50)//100)
    return [v[0],v[1],(v[2]*32768+50)//100,(v[3]*65536+180)//360,
            min(1048575,(v[4]*freq+500)//1000),min(1048575,(v[5]*freq+500)//1000),percent(v[6]),
            min(1048575,(v[7]*freq+500)//1000)]+[percent(p) for p in v[8:]]

def write_vectors(name, rows):
    (ASSETS/name).write_text('\n'.join(' '.join(map(str,r)) for r in rows)+'\n',encoding='ascii')

def make_bank(steps):
    rng=random.Random(20261017)
    frames=[]
    # 覆盖全部模式、两个方向、粗调微调、限幅和反转。
    for mode in (0,1):
        frames.append([mode,0,1,0,1,255]+[1]*8)
        for direction, count, fine in [(1,520,0),(-1,520,0),(1,380,1),(-1,380,1)]:
            frames += [[mode,fine,1,0,0,0]+[direction]*8 for _ in range(count)]
    # 覆盖仅清一次／保留余量、仅 K4、无操作、禁止编辑和保留模式。
    for i in range(1200):
        frames.append([rng.randrange(4),rng.randrange(2),rng.randrange(2),int(i%31==0),int(i%19==0),rng.randrange(256) if i%7==0 else 0]+[rng.choice([-1,0,1]) for _ in range(8)])
    bank=Bank(steps)
    rows=[]
    for mode,fine,enable,target,clear,press,*delta in frames:
        bank.apply(mode,fine,enable,target,clear,press,delta)
        packed=sum((d & 3) << (2*k) for k,d in enumerate(delta))
        rows.append([mode,fine,enable,target,clear,press,packed]+bank.values+[bank.progress])
    write_vectors(f'bank_{steps}.txt',rows)

def make_encoder(freq):
    rows=[]
    # 覆盖每个合法整数相位、百分比及毫秒值，并同时改变其他字段，
    # 避免错误混合快照被恒定输入掩盖。
    for i in range(5001):
        v=[i%4,(i+1)%4,i%101,i%360,1+i%2000,2000-i%2000,(i*17)%101,i]
        v += [(i*j)%101 for j in (3,5,7,11,13)]
        rows.append(v+encode(v,freq))
    # 非法上游超范围值的防御测试：20 位输出必须饱和，不能截断回绕。
    v = [0,1,100,359,2047,2047,100,8191,100,100,100,100,100]
    rows.append(v+encode(v,freq))
    write_vectors(f'encoder_{freq}.txt',rows)


class MenuReference:
    """按使用说明解释单次按钮动作；此回归无存储响应，执行后等待。"""
    def __init__(self):
        self.page = 'play'
        self.selection = 0
    def step(self, press, mode):
        clear = 0
        if self.page == 'play':
            if press & 1:
                self.page, self.selection, clear = 'main', 0, 1
            elif press & 2:
                mode, clear = mode ^ 1, 1
        elif self.page == 'main':
            if press & 8 or (press & 1 and self.selection == 0):
                self.page, clear = 'play', 1
            elif press & 1:
                self.page = 'advanced' if self.selection == 3 else 'slots'
            elif press & 2:
                self.selection = max(0, self.selection - 1)
            elif press & 4 and self.selection < 3:
                self.selection += 1
        elif self.page == 'slots':
            if press & 8: self.page = 'main'
            elif press & 1: self.page = 'confirm'
        elif self.page == 'confirm':
            if press & 8: self.page = 'slots'
            elif press & 1: self.page = 'busy'
        elif self.page == 'advanced':
            if press & 9: self.page = 'main'
        return mode, self.page != 'play', clear

def make_control():
    rows=[]
    mode=0
    menu=False
    menu_model=MenuReference()
    rng=random.Random(41017)
    for i in range(512):
        press = i%16 if i<32 else rng.randrange(16)
        held = press | rng.randrange(16)
        mode,menu,clear=menu_model.step(press,mode)
        rows.append([press,held,mode,int(bool(held&8) and not menu),int(not menu),clear])
    write_vectors('control.txt',rows)

def make_pipeline():
    rng=random.Random(1017)
    bank=Bank(4)
    mode=0
    menu=False
    menu_model=MenuReference()
    previous_button=None
    previous_knob=None
    buttons=[]
    knobs=[]
    expected=[]
    versions=[encode(bank.values,48000)]
    # 定向测试 B2 切换后四次 K1 步进（只在首帧清余量），然后覆盖
    # 长按 B2／B4、菜单进出、恢复默认与旋转同帧以及空事件。
    levels=[0,2,10,8,9,0,8,0,2,0,0,0]
    for batch in range(160):
        b=levels[batch] if batch<len(levels) else rng.randrange(16)
        press=0 if previous_button is None else b & ~previous_button
        previous_button=b
        mode,menu,clear=menu_model.step(press,mode)
        fine=int(bool(b&8) and not menu)
        count=4 if batch<12 else rng.randrange(1,6)
        buttons.append([batch%16,b])
        for frame in range(count):
            states=255 if batch<12 else rng.randrange(256)
            dirs=255 if batch<12 else rng.randrange(256)
            held=0 if batch<8 else (255 if batch==8 else rng.randrange(256))
            if batch==11: states=0;held=0
            kp=0 if previous_knob is None else held & ~previous_knob
            previous_knob=held
            delta=[(1 if dirs&(1<<k) else -1) if states&(1<<k) else 0 for k in range(8)]
            bank.apply(mode,fine,int(not menu),0,clear if frame==0 else 0,kp,delta)
            knobs.append([batch%16,int(frame==count-1),states,dirs,held])
            expected.append(bank.values+[bank.progress])
            versions.append(encode(bank.values,48000))
    write_vectors('pipeline_buttons.txt',buttons)
    write_vectors('pipeline_knobs.txt',knobs)
    write_vectors('pipeline_expected.txt',expected)
    write_vectors('pipeline_versions.txt',versions)
    write_vectors('pipeline_final.txt',[encode(bank.values,48000)])

if __name__=='__main__':
    for steps in (1,2,4): make_bank(steps)
    for freq in (48000,44100,47971,1000,209715): make_encoder(freq)
    make_control()
    make_pipeline()
