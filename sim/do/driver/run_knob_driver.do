# Run from sim/: do do/driver/run_knob_driver.do
# Check PCB mapping, quadrature, debounce, event FIFO, UI handshake and reset; expect PASS.
onerror {abort all}
set SIM_LIB work_knob_driver
do do/common/setup.do
do do/common/compile_knob_driver.do
vlog -sv -work $SIM_LIB tb/drivers/knob_driver_tb.vt
vsim -t 1ps -voptargs=+acc -onfinish stop -wlf $SIM_LIB/knob_driver_tb.wlf $SIM_LIB.knob_driver_tb
do do/driver/wave_knob_driver.do
run -all
