# GUI: 从sim/运行 do do/test/run_test_full_system.do；成功后保留波形。
onerror {abort all}
set MT_RUN_NAME test_full_system
do do/common/output_paths.do
set SIM_LIB [file join $MT_AI sim test_full_system work]
file mkdir [file dirname $SIM_LIB]
if {![file isdirectory $SIM_LIB]} {vlib $SIM_LIB}
do do/common/compile_test_full_system.do
vsim -modelsimini $::env(MODELSIM) -L $SIM_LIB -L gw5a -t 1ps -onfinish stop -voptargs=+acc \
    -wlf [file join $MT_AI sim test_full_system test_full_system.wlf] $SIM_LIB.test_full_system_tb
do do/test/wave_test_full_system.do
run -all
