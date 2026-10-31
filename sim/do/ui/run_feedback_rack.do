onerror {quit -code 1 -force}
onbreak {resume}
file mkdir user_interface/results
set SIM_LIB work_feedback_rack
do do/common/setup.do
do do/common/compile_ui.do
vlog -sv -work $SIM_LIB ../src/fixed_points/signed_fp_norm.v ../src/fixed_points/signed_fp_op.v
vlog -sv -work $SIM_LIB ../src/audio/envelope.v ../src/audio/envelope_group.v ../src/audio/wavetable_interpolation.v ../src/audio/wavetable_synthesizer.v ../src/audio/channel_rack.v ../src/rom_wavetables/rom_wavetables.v
vlog -sv -work $SIM_LIB ../src/adsr_division/adsr_division.vo tb/ui/keyboard_rack_feedback_tb.vt
vsim -L gw5a -t 1ps -onfinish stop -wlf user_interface/results/feedback_rack.wlf $SIM_LIB.keyboard_rack_feedback_tb
run -all
if {[examine -radix unsigned sim:/keyboard_rack_feedback_tb/test_passed] != 1} {quit -code 1 -force}
quit -code 0 -force
