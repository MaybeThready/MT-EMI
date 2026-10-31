# 工作目录设为 sim，再通过 Execute Macro 执行；结束后保留波形。
set SIM_LIB work_user_interface_system_seed2026
do ../common/setup.do
file mkdir $SIM_LIB/results
do ../common/compile_ui.do
vlog -sv -work $SIM_LIB tb/ui/user_interface_system_tb.vt
vsim -t 1ps -onfinish stop -voptargs=+acc -wlf $SIM_LIB/results/user_interface_system_seed2026.wlf +ASSETS=../assets/ui/test_vectors/system +RESULTS=$SIM_LIB/results   -gSEED=2026 $SIM_LIB.user_interface_system_tb
do wave_user_interface_system.do
run -all
