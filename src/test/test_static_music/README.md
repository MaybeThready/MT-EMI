# test_static_music

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

- 按 C4、C4、G4、G4、A4、A4、G4、休止的顺序循环，每格约 250 ms、整句约 2 s。
- 一次只有一个音符发声，音符间有短暂静音；正常运行后 `status_led[1]` 逻辑值保持 0。
