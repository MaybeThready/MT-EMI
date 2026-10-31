onerror {quit -code 1 -force}
onbreak {resume}
set SIM_LIB work_ui_balance_tb
do do/common/setup.do
file mkdir drivers/results
do do/common/compile_ui.do
vlog -sv -work $SIM_LIB tb/ui/user_interface_preset_tb.vt
vsim -t 1ps -onfinish stop -gBALANCE_ONLY=1 -wlf drivers/results/ui_balance.wlf $SIM_LIB.user_interface_preset_tb
run -all
quit -code 0 -force
