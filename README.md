# MT-EMI

## 1. 项目概述

MT-EMI（Multi-Timbre Electronic Musical Instrument）是一款基于 Sipeed Tang Mega 138K Pro 的多音色电子乐器。项目使用 FPGA 完成琴键扫描、复音合成、音频效果处理、I2S 输出和 LCD 显示。

主要功能包括：

- 24 个触摸琴键，支持逐键力度、弯音轮和最多 32 个合成声部。
- 正弦、三角、锯齿、方波波表插值，ADSR 包络与失谐调节。
- 普通演奏与 C 大调调内三和弦模式；和弦模式下低音组触发和弦，高音组保持单音。
- 失真、合唱、延迟、混响四种效果，以及干湿比和音量控制。
- LCD 参数、波形与频谱显示；16 个 Flash 音色槽；两首 ROM 曲目的 AutoPlay。

详细操作见 [UI 交互设计](docs/UI交互设计.md)。

## 2. 工程结构

```text
MT-EMI/
├─ MT-EMI.gprj       Gowin 工程文件
├─ src/
│  ├─ top.v          正式顶层
│  ├─ audio/         相位、包络和波表合成
│  ├─ mixer/         混音与效果器
│  ├─ drivers/       外设驱动
│  ├─ ui/            交互逻辑
│  ├─ lcd_ui/        屏幕显示
│  ├─ system/        时钟、AutoPlay 和模块间桥接
│  └─ test/          独立上板测试顶层
├─ sim/              ModelSim testbench 与 .do 脚本
├─ assets/           波表、MIDI、LCD 资源与位流归档
├─ scripts/          资源生成及辅助脚本
└─ docs/             设计文档与开发规范
```

## 3. 开发与仿真

硬件型号为 `GW5AST-LV138FPG676AC1/I0`。在 Gowin EDA 中打开 [`MT-EMI.gprj`](MT-EMI.gprj)，以 `top` 为顶层，启用 [`src/MT-EMI.cst`](src/MT-EMI.cst) 和 [`src/MT-EMI.sdc`](src/MT-EMI.sdc)，综合布线并检查时序报告后生成位流。上板接线以 CST 为准。

ModelSim 仿真以 `sim/` 为当前目录，按需运行相应 `.do` 脚本。例如，`do do/system/run_full_top_peripherals.do` 测试正式顶层外设，`do do/audio/run_channel_rack.do` 测试音频机架。仿真编译库和波形保存在 `ai_workspace/`。

波表由 `python scripts/audio/generate_wavetables.py` 生成；AutoPlay 事件 ROM 由 `python scripts/audio/build_autoplay_rom.py` 从 `assets/midi/` 中的 MIDI 文件生成。重新生成资源后需要重新综合布线。

## 4. 使用说明

按 K16 复位后进入演奏界面。触摸琴键发声，按 B1 打开菜单，B2／B3 选择项目，B4 返回；八个旋钮用于调节音色和效果，按下旋钮可恢复对应参数默认值。菜单支持演奏模式切换、音色保存／读取、高级音效设置和 AutoPlay。具体按键、旋钮及接线方法见 [UI 交互设计](docs/UI交互设计.md)与[正式物理约束](src/MT-EMI.cst)。
