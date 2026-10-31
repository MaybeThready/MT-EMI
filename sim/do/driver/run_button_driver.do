# 从 sim/ 执行：do do/driver/run_button_driver.do
# 检查 12 kHz 扫描、1 ms 消抖、握手背压及复位。
onerror {abort all}
set SIM_LIB work_button_driver
do do/common/setup.do
vlog -sv -work $SIM_LIB ../src/common/clock_divider.v
vlog -sv -work $SIM_LIB ../src/signal_detection/signal_edge_detector.v
vlog -sv -work $SIM_LIB ../src/signal_detection/signal_sync.v
vlog -sv -work $SIM_LIB ../src/system/sys_ticker.v
vlog -sv -work $SIM_LIB ../src/drivers/button_driver.v
vlog -sv -work $SIM_LIB tb/drivers/button_driver_tb.vt
vsim -t 1ps -voptargs=+acc -onfinish stop -wlf $SIM_LIB/button_driver_tb.wlf $SIM_LIB.button_driver_tb
do do/driver/wave_button_driver.do
run -all
