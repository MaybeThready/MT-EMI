# From formal sim; actual vendor LCD memories, no Gowin project writes.
onerror {quit -code 1 -force}
onbreak {}
set SIM_LIB ../ai_workspace/sim/work_formal_chord_lcd_units
do do/common/setup.do
file mkdir $SIM_LIB/results
transcript file $SIM_LIB/results/run.log
transcript on
do do/common/setup_gowin.do
do do/lcd_ui/compile_chord_lcd.do
vlog -sv -work $SIM_LIB tb/lcd_ui/lcd_memory_models.vt tb/lcd_ui/lcd_chord_memory_tb.vt
vlog -sv -work $SIM_LIB tb/lcd_ui/ui_interaction_tb.vt tb/lcd_ui/lcd_scene_motion_tb.vt tb/lcd_ui/drawers_tb.vt tb/lcd_ui/lcd_chord_draw_tb.vt
vlog -sv -work $SIM_LIB tb/drivers/lcd_driver_tb.vt
foreach test {lcd_chord_memory ui_interaction lcd_scene_motion drawers lcd_chord_draw lcd_driver} {
    vsim -L gw5a -t 1ps -onfinish stop -wlf $SIM_LIB/results/${test}.wlf $SIM_LIB.${test}_tb +RESULTS=$SIM_LIB/results
    run -all
    if {[examine -radix unsigned sim:/${test}_tb/test_passed]!=1} {quit -code 1 -force}
    quit -sim
}
echo CHORD_LCD_UNITS_PASS
if {![info exists CHORD_LCD_SUITE]} {quit -code 0 -force}
