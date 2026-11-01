# Execute from ai_workspace/sim. No synthesis or place-and-route.
onerror {quit -code 1 -force}
onbreak {resume}
do do/common/setup_gowin.do
set SIM_LIB lcd_ui/work_handoff_units
file mkdir lcd_ui/results
do do/common/setup.do
vlog -sv -work $SIM_LIB ../src/common/fsm.v
vlog -sv -work $SIM_LIB ../src/fixed_points/unsigned_fp_norm.v
vlog -sv -work $SIM_LIB ../src/fixed_points/unsigned_fp_op.v
foreach source [glob ../src/ui/*.v] {vlog -sv -work $SIM_LIB $source}
vlog -sv -work $SIM_LIB ../src/drivers/lcd_sdp_ram.v
vlog -sv -work $SIM_LIB ../src/lcd_ui/lcd_pcm_capture.v ../src/lcd_ui/lcd_waveform_builder.v
do do/common/compile_lcd_spectrum.do
vlog -sv -work $SIM_LIB ../src/lcd_ui/ui_interaction.v
vlog -sv -work $SIM_LIB tb/ui/ui_display_snapshot_tb.vt tb/lcd_ui/ui_interaction_tb.vt tb/ui/knob_display_tb.vt
foreach test {ui_display_snapshot ui_interaction knob_display} {
    vsim -L gw5a -t 1ps -onfinish stop -wlf lcd_ui/results/${test}.wlf $SIM_LIB.${test}_tb
    run -all
    if {[examine -radix unsigned sim:/${test}_tb/test_passed] != 1} {quit -code 1 -force}
    quit -sim
}
echo UI_HANDOFF_UNIT_SUITE_PASS
quit -code 0 -force
