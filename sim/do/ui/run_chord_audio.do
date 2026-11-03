# Run from formal sim/. Maintained chord regression; no synthesis/PnR.
onerror {quit -code 1 -force}
onbreak {}
set SIM_LIB ../ai_workspace/sim/work_formal_chord_audio
do do/common/setup.do
file mkdir $SIM_LIB/results
transcript file $SIM_LIB/results/run.log
transcript on
do do/common/setup_gowin.do
do do/common/compile_chord_audio.do
vlog -sv -work $SIM_LIB tb/ui/user_interface_chord_tb.vt
vsim -L gw5a -t 1ps -onfinish stop -voptargs=+acc -wlf $SIM_LIB/results/chord_audio.wlf $SIM_LIB.user_interface_chord_tb
log sim:/user_interface_chord_tb/clk_sys sim:/user_interface_chord_tb/tick
log sim:/user_interface_chord_tb/keys sim:/user_interface_chord_tb/buttons
log sim:/user_interface_chord_tb/in_valid sim:/user_interface_chord_tb/in_ready
log sim:/user_interface_chord_tb/pcm sim:/user_interface_chord_tb/pcm_valid sim:/user_interface_chord_tb/pcm_ready
log sim:/user_interface_chord_tb/display_state sim:/user_interface_chord_tb/display_valid sim:/user_interface_chord_tb/display_ready
log sim:/user_interface_chord_tb/config_error sim:/user_interface_chord_tb/overrun
log sim:/user_interface_chord_tb/dut/note_on sim:/user_interface_chord_tb/dut/note_off sim:/user_interface_chord_tb/dut/note_busy
log sim:/user_interface_chord_tb/dut/ui_valid sim:/user_interface_chord_tb/dut/ui_audio_ready
run -all
if {[examine -radix unsigned sim:/user_interface_chord_tb/test_passed] != 1} {quit -code 1 -force}
quit -sim
echo CHORD_AUDIO_PASS

if {![info exists CHORD_SUITE]} {quit -code 0 -force}
