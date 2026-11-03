# From sim/: do do/test/run_test_velocity_routing.do
onerror {abort all}
set SIM_LIB work_test_velocity_routing
do do/common/setup.do
do do/common/compile_test_velocity.do
vlog -sv -work $SIM_LIB tb/test/test_velocity_routing_tb.vt
vsim -t 1ps -onfinish stop -wlf $SIM_LIB/test_velocity_routing_tb.wlf $SIM_LIB.test_velocity_routing_tb
do do/test/wave_test_velocity_routing.do
run -all
