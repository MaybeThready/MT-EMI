# Run from formal sim/. Maintained chord regression; no synthesis/PnR.
onerror {quit -code 1 -force}
onbreak {}
set SIM_LIB ../ai_workspace/sim/work_formal_chord_pll
do do/common/setup.do
file mkdir $SIM_LIB/results
transcript file $SIM_LIB/results/run.log
transcript on
set CHORD_REAL_PLL 1
do do/common/compile_chord_system.do
set CHORD_SYSTEM_FULL 0
vsim -L gw5a -t 1ps -onfinish stop -gUSE_REAL_PLL=1 -gFULL_WINDOWS=$CHORD_SYSTEM_FULL -wlf $SIM_LIB/results/chord_system.wlf $SIM_LIB.chord_system_tb
log sim:/chord_system_tb/keys sim:/chord_system_tb/ui_button_n sim:/chord_system_tb/last_display sim:/chord_system_tb/last_render
log sim:/chord_system_tb/dut/note_on sim:/chord_system_tb/dut/note_off sim:/chord_system_tb/dut/played_pcm
run -all
if {[examine -radix unsigned sim:/chord_system_tb/test_passed]!=1} {quit -code 1 -force}
quit -sim
unset -nocomplain CHORD_SYSTEM_FULL
echo CHORD_FORMAL_SYSTEM_PASS

if {![info exists CHORD_LCD_SUITE]} {quit -code 0 -force}
