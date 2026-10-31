# Run from sim/: do do/driver/run_pitch_bend_frequency_mapper.do
# Check pitch range, monotonicity, rounding, saturation, handshake and reset; expect PASS.
onerror {abort all}
set SIM_LIB work_pitch_bend_frequency_mapper
do do/common/setup.do
do do/common/compile_pitch_bend_frequency_mapper.do
vlog -sv -work $SIM_LIB tb/drivers/pitch_bend_frequency_mapper_tb.vt
vsim -t 1ps -voptargs=+acc -onfinish stop -wlf $SIM_LIB/pitch_bend_frequency_mapper_tb.wlf $SIM_LIB.pitch_bend_frequency_mapper_tb
do do/driver/wave_pitch_bend_frequency_mapper.do
run -all
