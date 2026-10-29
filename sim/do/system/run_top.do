# 工作目录为 sim；本机须配置高云 gw5a 原语库。使用真实 PLL 模型验证诊断顶层。
set SIM_LIB work_top_tb
do ../common/setup.do
file mkdir $SIM_LIB/results
do ../common/compile_ui.do
vlog -sv -work $SIM_LIB ../src/signal_detection/signal_sync.v
vlog -sv -work $SIM_LIB ../src/pll_init.v
vlog -sv -work $SIM_LIB ../src/gowin_pll/gowin_pll_mod.v
vlog -sv -work $SIM_LIB ../src/gowin_pll/gowin_pll.v
vlog -sv -work $SIM_LIB ../src/system/sys_clocker.v
vlog -sv -work $SIM_LIB +incdir+../src ../src/top.v
vlog -sv -work $SIM_LIB tb/top_tb.vt
vsim -t 1ps -onfinish stop -voptargs=+acc -L gw5a -wlf $SIM_LIB/results/top_tb.wlf $SIM_LIB.top_tb
add wave sim:/top_tb/*
add wave sim:/top_tb/top_u/source_bend_r
add wave sim:/top_tb/top_u/source_valid_r
add wave sim:/top_tb/top_u/source_ready
run -all
