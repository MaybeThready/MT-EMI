# test_keyboard_interaction

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

- 按下琴键时对应音符发声，松开后包络逐渐释放；快速重复按放不应卡音。
- 同时按住多个键可听到和弦，各音分别释放；正常时 `status_led[1]` 逻辑值保持 0。
