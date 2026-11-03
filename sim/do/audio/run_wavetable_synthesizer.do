set SIM_LIB work_wavetable_synthesizer
do ../common/setup.do
do ../common/compile_ticker.do
do ../common/compile_wavetable_interpolation.do

vlog -sv -work $SIM_LIB ../src/audio/wavetable_synthesizer.v
vlog -sv -work $SIM_LIB tb/audio/wavetable_synthesizer_tb.vt

vsim -t 1ps -voptargs=+acc -L gw5a $SIM_LIB.wavetable_synthesizer_tb
# 记录数据，便于仿真结束后继续手动添加其他信号。
log sim:/wavetable_synthesizer_tb/*
log sim:/wavetable_synthesizer_tb/ws_u/stc
log sim:/wavetable_synthesizer_tb/ws_u/voice_index
log sim:/wavetable_synthesizer_tb/ws_u/batch_index
log sim:/wavetable_synthesizer_tb/ws_u/voice_point_r
log sim:/wavetable_synthesizer_tb/ws_u/voice_sample
log sim:/wavetable_synthesizer_tb/ws_u/audio_sum_r
do wave_wavetable_synthesizer.do
run -all
