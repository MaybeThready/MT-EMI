set MT_RUN_NAME run_spectrum_switch
unset -nocomplain MT_LOG_TARGET
do do/common/output_paths.do
# LCD波形/频谱切换与共享缓存所有权回归。
# 仿真DO文件从正式sim目录执行；实现TCL由用户在工具中自行运行。
onerror {quit -code 1 -force}
onbreak {resume}
do do/common/setup_gowin.do
set SIM_LIB work_spectrum_switch
do do/common/setup.do
file mkdir $LCD_RESULTS
vlog -sv -work $SIM_LIB ../src/common/fsm.v ../src/drivers/lcd_sdp_ram.v
do do/common/compile_lcd_spectrum.do
vlog -sv -work $SIM_LIB ../src/lcd_ui/lcd_pcm_capture.v ../src/lcd_ui/lcd_waveform_builder.v ../src/lcd_ui/ui_interaction.v
vlog -sv -work $SIM_LIB tb/lcd_ui/ui_spectrum_switch_tb.vt
vsim -L gw5a -t 1ps -onfinish stop -voptargs=+acc -wlf $LCD_RESULTS/spectrum_switch.wlf $SIM_LIB.ui_spectrum_switch_tb
run -all
if {[examine -radix unsigned sim:/ui_spectrum_switch_tb/test_passed]!=1} {quit -code 1 -force}
echo SPECTRUM_SWITCH_SUITE_PASS
quit -code 0 -force
