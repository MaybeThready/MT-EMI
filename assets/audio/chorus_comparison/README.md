# 合唱干湿音频对比

运行 `python scripts/audio/generate_chorus_comparison.py` 重新生成音频。

四个文件都是 48 kHz、单声道、16 位 PCM，长 19 秒：

- `dry.wav`：合唱模块输入的原始音乐。
- `mixed.wav`：rate 0.75 Hz、depth 96 个采样、mix 0.5625 的效果器输出。
- `wet_only.wav`：同一延迟历史下的近似全湿输出。
- `mixed_level_matched.wav`：`mixed.wav` 调整聆听响度后的版本。

脚本逐采样模拟 RTL 的三角 LFO、1024 字环形 RAM、两个相邻历史采样的插值、定点舍入和 24 位饱和。输入来自共用的确定性乐曲生成器，并非 `channel_rack` 的逐周期仿真。WAV 转 16 位时对前三个文件使用相同的最终增益。
