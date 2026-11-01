# From sim/: do do/test/run_test_velocity_auto.do
onerror {abort all}
set SIM_LIB work_test_velocity_auto
do do/common/setup.do
do do/common/compile_test_velocity.do
vlog -sv -work $SIM_LIB tb/test/test_velocity_auto_tb.vt
vsim -t 1ps -L $SIM_LIB -L $GOWIN_SIM_LIB -onfinish stop -wlf $SIM_LIB/test_velocity_auto_tb.wlf $SIM_LIB.test_velocity_auto_tb
do do/test/wave_test_velocity_auto.do
run -all
