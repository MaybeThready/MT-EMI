onerror {quit -code 1 -force}
onbreak {resume}
do do/common/setup_gowin.do
set SIM_LIB work_spectrum_columns
do do/common/setup.do
file mkdir lcd_ui/results
vlog -sv -work $SIM_LIB ../src/common/fsm.v ../src/drivers/lcd_sdp_ram.v
do do/common/compile_lcd_spectrum.do
vlog -sv -work $SIM_LIB tb/lcd_ui/lcd_spectrum_builder_tb.vt
foreach columns {544 800 1 32 1024} {
    set quick [expr {$columns!=544}]
    vsim -L gw5a -t 1ps -onfinish stop -gCOLUMNS=$columns -gQUICK=$quick -wlf lcd_ui/results/spectrum_${columns}.wlf $SIM_LIB.lcd_spectrum_builder_tb
    run -all
    if {[examine -radix unsigned sim:/lcd_spectrum_builder_tb/test_passed]!=1} {quit -code 1 -force}
    quit -sim
}
vsim -L gw5a -t 1ps -onfinish stop -gSAMPLE_NUM=48000 -gSAMPLE_DEN=1 -gVIEW_HZ=24000 -gQUICK=1 -wlf lcd_ui/results/spectrum_full_band.wlf $SIM_LIB.lcd_spectrum_builder_tb
run -all
if {[examine -radix unsigned sim:/lcd_spectrum_builder_tb/test_passed]!=1} {quit -code 1 -force}
echo SPECTRUM_COLUMNS_SUITE_PASS
quit -code 0 -force
