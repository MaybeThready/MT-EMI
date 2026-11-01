# Run from ai_workspace/sim. Real vendor SDP models; fresh isolated library.
onerror {quit -code 1 -force}
onbreak {resume}
do do/common/setup_gowin.do
set SIM_LIB lcd_ui/work_audio_units
file mkdir lcd_ui/results
do do/common/setup.do
vlog -sv -work $SIM_LIB ../src/common/fsm.v ../src/drivers/lcd_sdp_ram.v
vlog -sv -work $SIM_LIB ../src/lcd_ui/lcd_pcm_capture.v ../src/lcd_ui/lcd_waveform_builder.v
vlog -sv -work $SIM_LIB tb/lcd_ui/lcd_pcm_capture_tb.vt tb/lcd_ui/lcd_waveform_builder_tb.vt
vsim -L gw5a -t 1ps -onfinish stop -wlf lcd_ui/results/pcm_capture.wlf $SIM_LIB.lcd_pcm_capture_tb
run -all
if {[examine -radix unsigned sim:/lcd_pcm_capture_tb/test_passed] != 1} {quit -code 1 -force}
quit -sim
foreach columns {544 800 1 1024} {
    vsim -L gw5a -t 1ps -onfinish stop -gCOLUMNS=$columns -wlf lcd_ui/results/waveform_${columns}.wlf $SIM_LIB.lcd_waveform_builder_tb
    run -all
    if {[examine -radix unsigned sim:/lcd_waveform_builder_tb/test_passed] != 1} {quit -code 1 -force}
    quit -sim
}
echo AUDIO_RECEIVE_UNIT_SUITE_PASS
quit -code 0 -force
