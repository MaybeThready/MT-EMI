set SIM_LIB work_mixer
do ../common/setup.do
do ../common/setup_gowin.do
set MIXER_RESULTS [file join $MT_AI sim mixer results]
file mkdir $MIXER_RESULTS

vlog -sv -work $SIM_LIB ../src/common/fsm.v
vlog -sv -work $SIM_LIB ../src/fixed_points/signed_fp_norm.v
vlog -sv -work $SIM_LIB ../src/fixed_points/signed_fp_op.v
vlog -sv -work $SIM_LIB ../src/audio_mix_buffer/audio_mix_buffer.v
vlog -sv -work $SIM_LIB ../src/mixer/distortion.v
vlog -sv -work $SIM_LIB ../src/mixer/chorus.v
vlog -sv -work $SIM_LIB ../src/mixer/delay.v
vlog -sv -work $SIM_LIB ../src/mixer/reverb.v
vlog -sv -work $SIM_LIB ../src/mixer/mixer.v
vlog -sv -work $SIM_LIB tb/mixer/mixer_tb.vt

vsim -t 1ps -voptargs=+acc -L gw5a -wlf [file join $MIXER_RESULTS mixer.wlf] $SIM_LIB.mixer_tb
log sim:/mixer_tb/observed_audio
log sim:/mixer_tb/mixer_u/stc
do wave_mixer.do
run -all
