set MT_RUN_NAME run_audio_units
unset -nocomplain MT_LOG_TARGET
do do/common/output_paths.do
# LCD音频窗口与波形列单元回归，使用真实厂商SDP模型及独立仿真库。
# 仿真DO文件从正式sim目录执行；实现TCL由用户在工具中自行运行。
onerror {quit -code 1 -force}
onbreak {resume}
do do/common/setup_gowin.do
set SIM_LIB lcd_ui/work_audio_units
file mkdir $LCD_RESULTS
do do/common/setup.do
vlog -sv -work $SIM_LIB ../src/common/fsm.v ../src/drivers/lcd_sdp_ram.v
vlog -sv -work $SIM_LIB ../src/lcd_ui/lcd_pcm_capture.v ../src/lcd_ui/lcd_waveform_builder.v
vlog -sv -work $SIM_LIB tb/lcd_ui/lcd_pcm_capture_tb.vt tb/lcd_ui/lcd_waveform_builder_tb.vt
vsim -L gw5a -t 1ps -onfinish stop -wlf $LCD_RESULTS/pcm_capture.wlf $SIM_LIB.lcd_pcm_capture_tb
run -all
if {[examine -radix unsigned sim:/lcd_pcm_capture_tb/test_passed] != 1} {quit -code 1 -force}
quit -sim
foreach columns {544 800 1 1024} {
    vsim -L gw5a -t 1ps -onfinish stop -gCOLUMNS=$columns -wlf $LCD_RESULTS/waveform_${columns}.wlf $SIM_LIB.lcd_waveform_builder_tb
    run -all
    if {[examine -radix unsigned sim:/lcd_waveform_builder_tb/test_passed] != 1} {quit -code 1 -force}
    quit -sim
}
echo AUDIO_RECEIVE_UNIT_SUITE_PASS
quit -code 0 -force
