# test_pitch_bend

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
| `mux_addr[0]` | `T23` |
| `mux_addr[1]` | `R25` |
| `mux_addr[2]` | `W23` |
| `mux_addr[3]` | `U24` |
| `mux_en_a_n` | `AC26` |
| `mux_en_b_n` | `AB25` |
| `status_led[0]` | `J14` |
| `status_led[1]` | `R26` |
| `status_led[2]` | `L20` |
| `status_led[3]` | `M25` |
| `status_led[4]` | `N21` |
| `status_led[5]` | `N23` |

ADCLRC 硬核专用模拟引脚不属于顶层数字端口：弯音轮经 0～1 V 模拟前端后的正端接 **J4.3 / R12（ADCT+）**，负端接 **J4.1 / R11（ADCT−）** 并与模拟地共地。`test_pitch_bend.cst` 无需为这两个专用脚添加 `IO_LOC`。

## 预期结果

- 琴键与 FSR 的发声和力度响应同 `test_velocity`；弯音轮从低端到高端应连续改变音高，回中恢复原音高。
- 标称弯音范围约为 ±200 音分；力度调节仍有效，正常时故障指示 LED5 熄灭。
