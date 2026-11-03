# Run from sim/: do do/test/run_test_velocity.do
# Check real touch/FSR/UI/audio/I2S integration; expect PASS.
onerror {abort all}
set SIM_LIB work_test_velocity
do do/common/setup.do
do do/common/compile_test_velocity.do
vlog -sv -work $SIM_LIB tb/test/test_velocity_tb.vt
# TB references preserve the observed signals; avoid full +acc overhead in Starter Edition.
vsim -t 1ps -L $SIM_LIB -L $GOWIN_SIM_LIB -onfinish stop -wlf $SIM_LIB/test_velocity_tb.wlf $SIM_LIB.test_velocity_tb
do do/test/wave_test_velocity.do
run -all
