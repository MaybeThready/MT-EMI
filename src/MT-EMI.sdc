# 实际板载输入为 50 MHz；从真实 PLL 配置自动派生系统时钟。
# 不在 PLL 输出强行建立与实际配置矛盾的 98.304 MHz 理想时钟。
create_clock -name clk_core -period 20.000 [get_ports {clk_core}]
# Gowin 自动依据 PLL 参数传播时钟；derive_clocks -freq 是全局频率设置，不用于本处。
# 以下不确定度为离线工程预留预算；还不是测得的板载时钟抖动规格。
set_clock_uncertainty -setup 0.200 -to [all_clocks]
set_clock_uncertainty -hold 0.100 -to [all_clocks]
# 原始异步复位是例外；同步释放后的业务复位分发仍做恢复／移除检查。
set_false_path -from [get_ports {rst_n}]
# PLL 锁定／初始化结束是异步释放来源，只排除复位同步器的异步 CLEAR 入口。
# 不排除同步器 Q 到业务寄存器的恢复／移除检查，也不切断两个时钟域。
set_false_path -to [get_pins {sys_clocker_u/rst_sync_u/signal_buff1_0_s0/CLEAR}]
set_false_path -to [get_pins {sys_clocker_u/rst_sync_u/signal_buff2_0_s0/CLEAR}]
# 仅这两个已接电阻／LED 的输出没有同步采样沿，不适用外部建立／保持预算。
# 此例外不得复制到串口、I2S、SPI、并行数据或任何高速观察接口。
set_false_path -to [get_ports {status_led[*]}]
report_timing -setup -max_paths 100
report_timing -hold -max_paths 100
report_timing -recovery -max_paths 100
report_timing -removal -max_paths 100

