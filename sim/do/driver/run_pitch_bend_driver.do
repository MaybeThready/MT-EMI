# Run from sim/: do do/driver/run_pitch_bend_driver.do
# Check ADC protocol, calibrated pitch position and single-note frequency; expect PASS.
onerror {abort all}
set SIM_LIB work_pitch_bend_driver
do do/common/setup.do
do do/common/compile_pitch_bend_driver.do
vlog -sv -work $SIM_LIB tb/drivers/pitch_bend_driver_tb.vt
vsim -t 1ps -voptargs=+acc -onfinish stop -wlf $SIM_LIB/pitch_bend_driver_tb.wlf $SIM_LIB.pitch_bend_driver_tb
do do/driver/wave_pitch_bend_driver.do
run -all
