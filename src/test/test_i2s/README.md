# test_i2s

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

- 持续输出 A4 约 440 Hz 的正弦音，响度基本恒定，不应周期性静音或跳音。
- I2S 左声道有声、右声道静音；`status_led[0]` 的逻辑电平周期翻转，正常时 `status_led[1]` 逻辑值保持 0。
