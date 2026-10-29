set SIM_LIB work_channel_rack
do ../common/setup.do
do ../common/compile_channel_rack.do

vlog -sv -work $SIM_LIB tb/audio/channel_rack_tb.vt

vsim -t 1ps -voptargs=+acc -L gw5a $SIM_LIB.channel_rack_tb

# 保存结果，仿真停止后仍可在 GUI 中添加信号。
log sim:/channel_rack_tb/observed_audio
log sim:/channel_rack_tb/expected_audio
log sim:/channel_rack_tb/rack_u/stc
log sim:/channel_rack_tb/rack_u/lane_index
log sim:/channel_rack_tb/rack_u/synth_audio_out
do wave_channel_rack.do
run -all
