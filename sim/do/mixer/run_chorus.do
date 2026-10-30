set SIM_LIB work_chorus
do ../common/setup.do

vlog -sv -work $SIM_LIB ../src/common/fsm.v
vlog -sv -work $SIM_LIB ../src/fixed_points/signed_fp_norm.v
vlog -sv -work $SIM_LIB ../src/fixed_points/signed_fp_op.v
vlog -sv -work $SIM_LIB ../src/audio_mix_buffer/audio_mix_buffer.v
vlog -sv -work $SIM_LIB ../src/mixer/chorus.v
vlog -sv -work $SIM_LIB tb/mixer/chorus_tb.vt

vsim -t 1ps -voptargs=+acc -L gw5a $SIM_LIB.chorus_tb

log sim:/chorus_tb/observed_audio
log sim:/chorus_tb/chorus_u/stc
log sim:/chorus_tb/chorus_u/phase_r
do wave_chorus.do
run -all
