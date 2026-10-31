onerror {quit -code 1 -force}
onbreak {resume}
file mkdir user_interface/results
set SIM_LIB work_s2_context
do do/common/setup.do
do do/common/compile_ui.do
vlog -sv -work $SIM_LIB tb/ui/ui_control_state_tb.vt tb/ui/ui_input_frame_joiner_tb.vt
foreach tb {ui_control_state_tb ui_input_frame_joiner_tb} {
    vsim -t 1ps -onfinish stop +ASSETS=../assets/ui/test_vectors/control -wlf user_interface/results/${tb}_s2.wlf $SIM_LIB.$tb
    run -all
    quit -sim
}
quit -code 0 -force
