onerror {quit -code 1 -force}
onbreak {resume}
do do/common/setup_gowin.do
set SIM_LIB work_spectrum_switch
do do/common/setup.do
file mkdir lcd_ui/results
vlog -sv -work $SIM_LIB ../src/common/fsm.v ../src/drivers/lcd_sdp_ram.v
do do/common/compile_lcd_spectrum.do
vlog -sv -work $SIM_LIB ../src/lcd_ui/lcd_pcm_capture.v ../src/lcd_ui/lcd_waveform_builder.v ../src/lcd_ui/ui_interaction.v
vlog -sv -work $SIM_LIB tb/lcd_ui/ui_spectrum_switch_tb.vt
vsim -L gw5a -t 1ps -onfinish stop -wlf lcd_ui/results/spectrum_switch.wlf $SIM_LIB.ui_spectrum_switch_tb
run -all
if {[examine -radix unsigned sim:/ui_spectrum_switch_tb/test_passed]!=1} {quit -code 1 -force}
echo SPECTRUM_SWITCH_SUITE_PASS
quit -code 0 -force
