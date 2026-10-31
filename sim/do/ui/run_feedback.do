onerror {quit -code 1 -force}
onbreak {resume}
file mkdir user_interface/results
set SIM_LIB work_keyboard_feedback
do do/common/setup.do
do do/common/compile_ui.do
vlog -sv -work $SIM_LIB tb/ui/keyboard_feedback_tb.vt
vsim -t 1ps -onfinish stop -wlf user_interface/results/feedback.wlf $SIM_LIB.keyboard_feedback_tb
run -all
if {[examine -radix unsigned sim:/keyboard_feedback_tb/test_passed] != 1} {quit -code 1 -force}
quit -sim
vlog -sv -work $SIM_LIB tb/ui/voice_priority_feedback_tb.vt
vsim -t 1ps -onfinish stop -wlf user_interface/results/feedback_priority.wlf $SIM_LIB.voice_priority_feedback_tb
run -all
if {[examine -radix unsigned sim:/voice_priority_feedback_tb/test_passed] != 1} {quit -code 1 -force}
quit -code 0 -force
