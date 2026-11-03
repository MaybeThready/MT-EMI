# 公开 UI 与正式相位组联仿，24 键/32 声部。
set SIM_LIB work_user_interface_pitch_bend_tb
do ../common/setup.do
file mkdir $SIM_LIB/results
do ../common/compile_ui.do
vlog -sv -work $SIM_LIB tb/ui/user_interface_pitch_bend_tb.vt
vsim -t 1ps -onfinish stop -voptargs=+acc -wlf $SIM_LIB/results/user_interface_pitch_bend.wlf $SIM_LIB.user_interface_pitch_bend_tb
add wave sim:/user_interface_pitch_bend_tb/*
add wave -group keyboard sim:/user_interface_pitch_bend_tb/user_interface_u/keyboard_note_pipeline_u/current_state
add wave -group keyboard sim:/user_interface_pitch_bend_tb/user_interface_u/keyboard_note_pipeline_u/latest_bend_r
add wave -group keyboard sim:/user_interface_pitch_bend_tb/user_interface_u/keyboard_note_pipeline_u/bend_ratio
add wave -group keyboard sim:/user_interface_pitch_bend_tb/user_interface_u/keyboard_note_pipeline_u/note_pitch_bend_u/voice_index_r
run -all
