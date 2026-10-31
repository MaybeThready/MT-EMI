# 默认 32 声部；总回归另检查 1、3 声部。
set SIM_LIB work_note_pitch_bend_tb
do ../common/setup.do
file mkdir $SIM_LIB/results
do ../common/compile_unsigned_fp.do
vlog -sv -work $SIM_LIB ../src/common/fsm.v ../src/ui/note_pitch_bend.v
vlog -sv -work $SIM_LIB tb/ui/note_pitch_bend_tb.vt
vsim -t 1ps -onfinish stop -voptargs=+acc -wlf $SIM_LIB/results/note_pitch_bend.wlf $SIM_LIB.note_pitch_bend_tb
add wave sim:/note_pitch_bend_tb/*
run -all
