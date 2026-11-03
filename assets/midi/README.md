# AutoPlay 曲目

`The Star.mid` 与 `Everlasting Dirge.mid` 是原始曲目，请保留。运行 `python scripts/audio/build_autoplay_rom.py` 会从这两份 MIDI 重新生成 `autoplay_events.mi`、事件 ROM 和音高查找表。播放时间量化到 48 kHz 采样点，MIDI 力度按 `velocity × 516` 转为 UQ0.16；MIDI 同时发声的音符由播放器分配到八个独立声部。声部分配会为释放段预留 200 ms，减少连续音符截断尾音。

上板操作：主菜单第五项 AutoPlay，B2/B3 选曲，B1 开始，B4 停止并返回。当前音色与效果设置仍作用于自动演奏。

在 ModelSim 中以 `sim` 为工作目录，可运行 `do do/system/run_autoplay_player.do` 检查 ROM 事件、力度和结束信号，运行 `do do/ui/run_autoplay_menu.do` 检查菜单选择和 LCD 文字 ROM。仿真结果写入 `ai_workspace/sim/libraries/`。
