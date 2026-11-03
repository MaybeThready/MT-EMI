onerror {abort all}
set MT_RUN_NAME test_full_system_inputs
do do/common/output_paths.do
set SIM_LIB [file join $MT_AI sim test_full_system inputs]
file mkdir [file dirname $SIM_LIB]
if {![file isdirectory $SIM_LIB]} {vlib $SIM_LIB}
vlog -sv -work $SIM_LIB ../src/test/test_full_system/test_full_system_inputs.v tb/test/test_full_system_inputs_tb.vt
vsim -t 1ps -onfinish stop -wlf [file join $MT_AI sim test_full_system inputs.wlf] $SIM_LIB.test_full_system_inputs_tb
add wave -r sim:/test_full_system_inputs_tb/dut/*
run -all
