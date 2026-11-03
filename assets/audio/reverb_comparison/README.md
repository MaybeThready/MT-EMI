# 混响试听对比

运行 `python scripts/audio/generate_reverb_comparison.py` 可重新生成四个 48 kHz、单声道、16 位 PCM WAV。前 16 秒是波表和节奏组成的测试乐句，后 3 秒停止输入以观察混响尾音。

- `dry.wav`：送入混响模块的原始采样。
- `mixed.wav`：按 `reverb.v` 的 24 位计算流程和 `reverb_mix=0xC000` 得到的输出。
- `wet_only.wav`：同一次运算得到的湿声，按接近全湿的 `0xFFFF` 混合系数输出。
- `mixed_level_matched.wav`：将 `mixed.wav` 额外放大到接近干声的响度，便于听音对比；此额外增益不属于混响 RTL。

前三个文件采用相同的 WAV 导出增益，能直接比较实际电平。测试乐句由脚本生成，不声称逐周期模拟上游 `channel_rack`。脚本的六段延迟、启动时历史屏蔽、系数钳位、定点乘法舍入、饱和及最终干湿混合与当前 32 复音配置的 `reverb.v` 对应。参数为 `feedback=0xB000`、`damping=0x2800`、`mix=0xC000`。
