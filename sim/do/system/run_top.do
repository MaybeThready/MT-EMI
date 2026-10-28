# 工作目录设为 sim，再通过 Execute Macro 执行；结束后保留波形。
set SIM_LIB work_top_tb
do ../common/setup.do
file mkdir $SIM_LIB/results
do ../common/compile_ui.do
do ../common/compile_sys_clocker.do
vlog -sv -work $SIM_LIB ../src/top.v
vlog -sv -work $SIM_LIB tb/top_tb.vt
vsim -t 1ps -onfinish stop -voptargs=+acc -L gw5a -wlf $SIM_LIB/results/top_tb.wlf  $SIM_LIB.top_tb
do wave_top.do
run -all
