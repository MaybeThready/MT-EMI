# Run from formal sim/. No audio RTL replacement or layout flow.
onerror {quit -code 1 -force}
onbreak {resume}
do do/common/setup_gowin.do
set SIM_LIB lcd_ui/work_timer_optimization
do do/common/setup.do
file mkdir lcd_ui/results
vlog -sv -work $SIM_LIB ../src/common/fsm.v ../src/drivers/lcd_sdp_ram.v
do do/common/compile_lcd_spectrum.do
vlog -sv -work $SIM_LIB ../src/lcd_ui/lcd_pcm_capture.v ../src/lcd_ui/lcd_waveform_builder.v ../src/lcd_ui/ui_interaction.v
vlog -sv -work $SIM_LIB models/lcd_ui/ui_interaction_timer_reference.vt tb/lcd_ui/ui_interaction_timer_tb.vt
foreach parameters {{1000 1} {2000 2} {3000 3} {1000 255} {1000 256} {100000 800} {1000 65535} {98245614 1}} {
    lassign $parameters hz hold
    vsim -L gw5a -t 1ps -onfinish stop -gCLK_HZ=$hz -gHOLD_MS=$hold -wlf lcd_ui/results/timer_${hz}_${hold}.wlf $SIM_LIB.ui_interaction_timer_tb
    run -all
    if {[examine -radix unsigned sim:/ui_interaction_timer_tb/test_passed]!=1} {quit -code 1 -force}
    quit -sim
}
echo LCD_TIMER_OPTIMIZATION_SUITE_PASS
quit -code 0 -force
