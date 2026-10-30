# 失真干湿音频对比

运行 `python scripts/audio/generate_distortion_comparison.py` 重新生成音频。

四个文件都是 48 kHz、单声道、16 位 PCM，长 19 秒：

- `dry.wav`：输入到失真模块的原始音乐。
- `mixed.wav`：增益 4 倍、tone 0.6875、mix 0.75 的效果器输出。
- `wet_only.wav`：同一滤波状态下的近似全湿输出。
- `mixed_level_matched.wav`：`mixed.wav` 调整聆听响度后的版本，便于听音比较。

脚本逐采样模拟 RTL 的乘法舍入、16 位削波、tone 一阶低通、24 位干湿混合与饱和。输入来自共用的确定性乐曲生成器，并非 `channel_rack` 的逐周期仿真。WAV 转 16 位时对各文件使用相同的最终增益；响度匹配文件除外。
