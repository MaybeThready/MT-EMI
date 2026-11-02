# test_knob_driver

## 顶层端口与 FPGA 引脚

| 顶层端口 | FPGA 引脚 |
| --- | --- |
| `clk_core` | `P16` |
| `rst_n` | `K16` |
| `serial_data` | `W21` |
| `load_n` | `U16` |
| `shift_clk` | `U15` |
| `status_led[0]` | `J14` |
| `status_led[1]` | `R26` |
| `status_led[2]` | `L20` |
| `status_led[3]` | `M25` |
| `status_led[4]` | `N21` |
| `status_led[5]` | `N23` |

## 预期结果

- 旋转 K1～K8 时，`status_led[2:0]` 以低亮权值 1/2/4 显示最近操作的旋钮编号减 1；`status_led[3]` 显示最近的旋转方向。
- 按住任一旋钮时 `status_led[4]` 点亮；转动、按下或松开时 `status_led[5]` 短暂点亮。停止操作后 LED5 应熄灭，持续点亮表示扫描或队列故障。
