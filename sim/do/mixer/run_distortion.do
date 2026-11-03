set SIM_LIB work_distortion
do ../common/setup.do

vlog -sv -work $SIM_LIB ../src/common/fsm.v
vlog -sv -work $SIM_LIB ../src/fixed_points/signed_fp_norm.v
vlog -sv -work $SIM_LIB ../src/fixed_points/signed_fp_op.v
vlog -sv -work $SIM_LIB ../src/mixer/distortion.v
vlog -sv -work $SIM_LIB tb/mixer/distortion_tb.vt

vsim -t 1ps -voptargs=+acc $SIM_LIB.distortion_tb

log sim:/distortion_tb/observed_audio
log sim:/distortion_tb/distortion_u/stc
do wave_distortion.do
run -all
