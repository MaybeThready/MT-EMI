# 上板测试顶层

只使用根目录的 `MT-EMI.gprj`。每个测试模块在同名目录中放置 `*.v`、`*.cst`、`*.sdc` 和接线 `README.md`。在 Gowin 中将所需模块 **Set as Top**，禁用原来启用的 CST/SDC，只启用该目录的 CST/SDC；切回正式整机 `top` 时恢复 `src/MT-EMI.cst`、`src/MT-EMI.sdc`。同一轮构建只启用一份 CST 和一份 SDC。

| 测试顶层 | 目的 | 端口引脚与预期结果 |
| --- | --- | --- |
| `test_i2s` | 固定 440 Hz 正弦波与 I2S | [test_i2s](test_i2s/README.md) |
| `test_static_music` | 单声部自动乐句 | [test_static_music](test_static_music/README.md) |
| `test_dynamic_music` | 32 声部动态乐句 | [test_dynamic_music](test_dynamic_music/README.md) |
| `test_keyboard_interaction` | 双板键盘与 UI 发声 | [test_keyboard_interaction](test_keyboard_interaction/README.md) |
| `test_mixer` | 键盘与混音效果链 | [test_mixer](test_mixer/README.md) |
| `test_knob_driver` | 八旋钮驱动与事件 | [test_knob_driver](test_knob_driver/README.md) |
| `test_velocity` | 键盘与 24 路压力 | [test_velocity](test_velocity/README.md) |
| `test_velocity_auto` | 24 路压力自动诊断 | [test_velocity_auto](test_velocity_auto/README.md) |
| `test_pitch_bend` | 键盘力度与弯音轮 | [test_pitch_bend](test_pitch_bend/README.md) |
| `test_ui` | 键盘、旋钮、四按键、UI、LCD 与音频联合调试 | [test_ui](test_ui/README.md) |
| `test_full_system` | 24键/压力、弯音、旋钮、按钮、32声部、音效、LCD与Flash整机联合测试 | [test_full_system](test_full_system/README.md) |

`test_i2s` 至 `test_mixer` 的 CST/SDC 是依据现有测试引脚分配补齐的，尚未分别完成上板布线验证。力度、自动力度、弯音和旋钮测试沿用已有约束。所有测试更换顶层后都需重新综合、布线并检查时序；此前保存的位流可直接在 Programmer 中选择烧录。位流归档见 `scripts/manage_bitstreams.cmd`。

`test_velocity_auto` 和 `test_pitch_bend` 使用 `test_velocity.v` 内的 `test_velocity_core`，所以主工程需要同时启用 `test_velocity/test_velocity.v`。ModelSim 从 `sim` 目录运行相应的 `do/test/*.do`；测试脚本仍把库和波形放在 `ai_workspace` 下。
