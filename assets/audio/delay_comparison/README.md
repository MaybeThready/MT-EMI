# 延迟效果试听对比

运行 `python scripts/audio/generate_delay_comparison.py` 可重新生成四个 48 kHz、单声道、16 位 PCM WAV。输入与混响试听使用同一段波表乐句：前 16 秒有音符和节奏，后 3 秒停止输入以听回声尾音。

- `dry.wav`：送入延迟模块的原始采样。
- `mixed.wav`：按 `delay.v` 的 24 位运算流程，使用 `delay_mix=0x7000` 得到的输出。
- `wet_only.wav`：同一次运算得到的历史采样，按接近全湿的 `0xFFFF` 混合系数输出。
- `mixed_level_matched.wav`：额外调到接近干声响度，便于听音比较；额外增益不属于延迟 RTL。

前三个文件共用同一 WAV 导出增益。延迟时间为 12000 个采样周期，即 250 ms；反馈系数 `0x9000`。Python 模型按 RTL 的 65536 格环形 RAM、未写历史屏蔽、16 位系数乘法舍入及 24 位饱和逐采样计算。音源由脚本生成，不代表上游 `channel_rack` 的逐周期仿真。
