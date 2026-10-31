# Run from sim/: do do/driver/run_keyboard_driver.do
# Check key mapping, debounce, backpressure and reset; expect PASS.
onerror {abort all}
set SIM_LIB work_keyboard_driver
do ../common/setup.do
do ../common/compile_keyboard_driver.do
vlog -sv -work $SIM_LIB tb/drivers/keyboard_driver_tb.vt
vsim -t 1ps -voptargs=+acc -onfinish stop -wlf $SIM_LIB/keyboard_driver_tb.wlf $SIM_LIB.keyboard_driver_tb
do wave_keyboard_driver.do
run -all
