# 在 sim 目录执行；保留自检波形，公共库在首次运行时自动建立。
set SIM_LIB work_pitch_bend_controller_tb
do ../common/setup.do
file mkdir $SIM_LIB/results
vlog -sv -work $SIM_LIB ../src/common/fsm.v ../src/ui/pitch_bend_controller.v
vlog -sv -work $SIM_LIB tb/ui/pitch_bend_controller_tb.vt
vsim -t 1ps -onfinish stop -voptargs=+acc -wlf $SIM_LIB/results/pitch_bend_controller.wlf $SIM_LIB.pitch_bend_controller_tb
add wave sim:/pitch_bend_controller_tb/*
run -all
