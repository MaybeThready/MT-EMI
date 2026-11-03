set SIM_LIB work_reverb
do ../common/setup.do

vlog -sv -work $SIM_LIB ../src/common/fsm.v
vlog -sv -work $SIM_LIB ../src/fixed_points/signed_fp_norm.v
vlog -sv -work $SIM_LIB ../src/fixed_points/signed_fp_op.v
vlog -sv -work $SIM_LIB ../src/audio_mix_buffer/audio_mix_buffer.v
vlog -sv -work $SIM_LIB ../src/mixer/reverb.v
vlog -sv -work $SIM_LIB tb/mixer/reverb_tb.vt

vsim -t 1ps -voptargs=+acc -L gw5a $SIM_LIB.reverb_tb
log sim:/reverb_tb/observed_audio
log sim:/reverb_tb/reverb_u/stc
log sim:/reverb_tb/reverb_u/stage_index
do wave_reverb.do
run -all
