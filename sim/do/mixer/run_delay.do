set SIM_LIB work_delay
do ../common/setup.do

vlog -sv -work $SIM_LIB ../src/common/fsm.v
vlog -sv -work $SIM_LIB ../src/fixed_points/signed_fp_norm.v
vlog -sv -work $SIM_LIB ../src/fixed_points/signed_fp_op.v
vlog -sv -work $SIM_LIB ../src/audio_mix_buffer/audio_mix_buffer.v
vlog -sv -work $SIM_LIB ../src/mixer/delay.v
vlog -sv -work $SIM_LIB tb/mixer/delay_tb.vt

vsim -t 1ps -voptargs=+acc -L gw5a $SIM_LIB.delay_tb
log sim:/delay_tb/observed_audio
log sim:/delay_tb/delay_u/stc
log sim:/delay_tb/delay_u/write_ptr_r
do wave_delay.do
run -all
