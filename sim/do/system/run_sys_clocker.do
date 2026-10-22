set SIM_LIB work_sys_clocker
do ../common/setup.do
do ../common/compile_sys_clocker.do
vlog -sv -work $SIM_LIB tb/system/sys_cloker_tb.vt
vsim -t 1ps -voptargs=+acc -L gw5a $SIM_LIB.sys_clocker_tb
do wave_sys_clocker.do
run -all

