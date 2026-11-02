# From sim/: do do/test/run_test_pitch_bend.do
onerror {abort all}
file mkdir ../ai_workspace
set SIM_LIB ../ai_workspace/work_test_pitch_bend
do do/common/setup.do
do do/common/compile_test_velocity.do
vlog -sv -work $SIM_LIB ../src/drivers/pitch_bend_driver.v
vlog -sv -work $SIM_LIB ../src/drivers/shared_adc_manager.v
vlog -sv +incdir+../src/audio -work $SIM_LIB ../src/test/test_pitch_bend/test_pitch_bend.v
vlog -sv -work $SIM_LIB tb/test/test_pitch_bend_tb.vt
vsim -t 1ps -L $SIM_LIB -L $GOWIN_SIM_LIB -onfinish stop \
    -wlf $SIM_LIB/test_pitch_bend_tb.wlf $SIM_LIB.test_pitch_bend_tb
do do/test/wave_test_pitch_bend.do
run -all
