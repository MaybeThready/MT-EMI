# From sim/: do do/test/run_test_knob_driver.do
# Check all eight knobs through the real scanner, UI event handshake and board LED logic.
onerror {abort all}
set SIM_LIB work_test_knob_driver
do do/common/setup.do
do do/common/compile_test_knob_driver.do
vlog -sv -work $SIM_LIB tb/test/test_knob_driver_tb.vt
vsim -t 1ps -voptargs=+acc -onfinish stop -wlf $SIM_LIB/test_knob_driver_tb.wlf $SIM_LIB.test_knob_driver_tb
do do/test/wave_test_knob_driver.do
run -all
