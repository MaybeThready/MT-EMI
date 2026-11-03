set MT_RUN_NAME run_chord_handoff
unset -nocomplain MT_LOG_TARGET
do do/common/output_paths.do
# Existing full UI/preset/display handoff regression with the new LCD receiver.
onerror {quit -code 1 -force}
onbreak {}
set SIM_LIB ../ai_workspace/sim/work_formal_chord_lcd_handoff
do do/common/setup.do
file mkdir $SIM_LIB/results
transcript file $SIM_LIB/results/run.log
transcript on
do do/common/setup_gowin.do
do do/lcd_ui/compile_chord_lcd.do
vlog -sv -work $SIM_LIB tb/lcd_ui/ui_display_handoff_tb.vt
vsim -L gw5a -t 1ps -onfinish stop -wlf $SIM_LIB/results/handoff.wlf $SIM_LIB.ui_display_handoff_tb
run -all
if {[examine -radix unsigned sim:/ui_display_handoff_tb/test_passed]!=1} {quit -code 1 -force}
quit -sim
echo CHORD_LCD_HANDOFF_PASS
if {![info exists CHORD_LCD_SUITE]} {quit -code 0 -force}
