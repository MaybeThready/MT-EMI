onerror {quit -code 1 -force}
onbreak {resume}
do do/common/setup_gowin.do
set SIM_LIB lcd_ui/work_handoff_integration
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
vlog -sv -work $SIM_LIB tb/lcd_ui/ui_display_handoff_tb.vt
vsim -L gw5a -t 1ps -onfinish stop -wlf lcd_ui/results/ui_display_handoff.wlf $SIM_LIB.ui_display_handoff_tb
run -all
if {[examine -radix unsigned sim:/ui_display_handoff_tb/test_passed] != 1} {quit -code 1 -force}
echo UI_HANDOFF_INTEGRATION_SUITE_PASS
quit -code 0 -force
