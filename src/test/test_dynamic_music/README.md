# test_dynamic_music

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

- 依次演奏 C4 C4 G4 G4 A4 A4 G4、F4 F4 E4 E4 D4 D4 C4，每格约 250 ms，约 3.5 s 循环。
- 相邻音符的释放尾音可短暂重叠，正弦波和三角波插值使音色规律变化；正常时 `status_led[1]` 逻辑值保持 0。
