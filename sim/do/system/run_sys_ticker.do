set SIM_LIB work_sys_ticker
do ../common/setup.do
do ../common/compile_ticker.do
vlog -sv -work $SIM_LIB tb/system/sys_ticker_tb.vt
vsim -t 1ps -voptargs=+acc $SIM_LIB.sys_ticker_tb
do wave_sys_ticker.do
run -all

