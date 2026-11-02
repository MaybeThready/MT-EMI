# test_velocity

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

- 24 个琴键应触发各自音高；按住时，对应 FSR 压力增大应使该音更响，按其他 FSR 不应改变它。
- `status_led[0]` 为心跳，LED1 表示有键按住，LED2/3 表示压力达到约 25%/75%；正常时削顶指示 LED4 和故障指示 LED5 熄灭。
