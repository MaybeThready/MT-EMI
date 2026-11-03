set MT_RUN_NAME run_spectrum_configuration
unset -nocomplain MT_LOG_TARGET
do do/common/output_paths.do
# LCD频谱配置边界回归，不运行综合或布局布线。
# 仿真DO文件从正式sim目录执行；实现TCL由用户在工具中自行运行。
onerror {quit -code 1 -force}
onbreak {resume}
do do/common/setup_gowin.do
set SIM_LIB work_spectrum_configuration
do do/common/setup.do
file mkdir $LCD_RESULTS
vlog -sv -work $SIM_LIB ../src/common/fsm.v ../src/drivers/lcd_sdp_ram.v
do do/common/compile_lcd_spectrum.do
vlog -sv -work $SIM_LIB ../src/lcd_ui/lcd_pcm_capture.v ../src/lcd_ui/lcd_waveform_builder.v ../src/lcd_ui/ui_interaction.v
vlog -sv -work $SIM_LIB tb/lcd_ui/ui_spectrum_configuration_tb.vt
foreach bad {1 2 3 4 5 6 7 8 9 10} {
    vsim -L gw5a -t 1ps -onfinish stop -gBAD_CASE=$bad -wlf $LCD_RESULTS/spectrum_configuration_${bad}.wlf $SIM_LIB.ui_spectrum_configuration_tb
    run -all
    if {[examine -radix unsigned sim:/ui_spectrum_configuration_tb/test_passed]!=1} {quit -code 1 -force}
    quit -sim
}
echo SPECTRUM_CONFIGURATION_SUITE_PASS
quit -code 0 -force
