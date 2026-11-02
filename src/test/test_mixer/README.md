# test_mixer

## 顶层端口与 FPGA 引脚

| 顶层端口 | FPGA 引脚 |
| --- | --- |
| `clk_core` | `P16` |
| `rst_n` | `K16` |
| `data_a` | `W21` |
| `data_b` | `P21` |
| `load_n` | `U16` |
| `key_clk` | `U15` |
| `i2s_bclk` | `C21` |
| `i2s_lrck` | `B20` |
| `i2s_dout` | `B19` |
| `sd_mode_n` | `A17` |
| `status_led[0]` | `J14` |
| `status_led[1]` | `R26` |

## 预期结果

- 琴键按下、松开与和弦行为同键盘交互测试，声音经混音效果链输出。
- 按当前 `test_mixer.v` 参数，预期能听到混响和延迟尾音；失真与合唱的 mix 为 0。正常时 `status_led[1]` 逻辑值保持 0。
