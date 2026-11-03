# ModelSim命令行入口：单元/整机自检不通过时返回非零状态。
onerror {quit -code 1 -force}
onbreak {}
set MT_RUN_NAME test_full_system_batch
do do/common/output_paths.do
set SIM_LIB [file join $MT_AI sim test_full_system work]
file mkdir [file dirname $SIM_LIB]
if {![file isdirectory $SIM_LIB]} {vlib $SIM_LIB}
do do/common/compile_test_full_system.do
foreach test {test_full_system_inputs_tb test_full_system_tb} {
    vsim -modelsimini $::env(MODELSIM) -L $SIM_LIB -L gw5a -t 1ps -onfinish stop \
        -wlf [file join $MT_AI sim test_full_system ${test}_batch.wlf] $SIM_LIB.$test
    run -all
    if {[examine -radix unsigned sim:/$test/test_passed] != 1} {quit -code 1 -force}
    quit -sim
}
echo TEST_FULL_SYSTEM_BATCH_PASS
quit -code 0 -force
