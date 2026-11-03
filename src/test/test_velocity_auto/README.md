# test_velocity_auto

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

## 预期结果

- 无需按键，自动从 FSR1 到 FSR24 逐路发音，每约 2 s 切换一路，约 48 s 循环。
- 仅当前路 FSR 的压力改变当前音量；LED0～4 以低亮二进制表示当前 FSR 编号减 1，正常时故障灯 LED5 熄灭。
