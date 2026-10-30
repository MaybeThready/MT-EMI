# Mixer 试听对照

运行 `python scripts/audio/generate_mixer_comparison.py` 重新生成 48 kHz、单声道、16 位 PCM 文件。音源来自现有的确定性复音乐句，不是 `channel_rack` 的逐时钟仿真。

- `dry.wav`：同一输入直接经过 balance、master、固定除以 8 和最终限幅。
- `processed.wav`：失真 → 合唱 → 延迟 → 混响 → balance → master → 固定除以 8 → 最终限幅。该文件的 PCM 采样值由各效果器的定点参考模型逐样本计算。
- `processed_level_matched.wav`：仅供听感比较，对 `processed.wav` 另加统一的后期音量，不代表 RTL 输出。

参数固定在脚本开头。`dry.wav` 和 `processed.wav` 使用相同的最终音量设定；因此两个文件的实际响度差异也属于处理结果。

运行 `python scripts/audio/generate_mixer_comparison.py --vectors` 可重建 `sim/tb/mixer/mixer_vectors.mem`，供 ModelSim 集成仿真逐样本对照。
