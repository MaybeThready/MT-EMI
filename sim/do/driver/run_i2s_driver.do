# Run from sim/: do do/driver/run_i2s_driver.do
# Check mono data, right-channel silence, handshake, timing and reset; expect PASS.
onerror {abort all}
set SIM_LIB work_i2s_driver
do do/common/setup.do
do do/common/compile_i2s_driver.do
vlog -sv -work $SIM_LIB tb/drivers/i2s_driver_tb.vt
vsim -t 1ps -voptargs=+acc -onfinish stop -wlf $SIM_LIB/i2s_driver_tb.wlf $SIM_LIB.i2s_driver_tb
do do/driver/wave_i2s_driver.do
run -all
