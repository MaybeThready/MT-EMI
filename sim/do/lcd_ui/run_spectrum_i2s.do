# I2S实际播放镜像到LCD频谱的联合回归。
# 仿真DO文件从正式sim目录执行；实现TCL由用户在工具中自行运行。
onerror {quit -code 1 -force}
onbreak {resume}
do do/common/setup_gowin.do
set SIM_LIB work_spectrum_i2s
do do/common/setup.do
file mkdir lcd_ui/results
vlog -sv -work $SIM_LIB +incdir+../src ../src/common/fsm.v ../src/common/clock_divider.v
vlog -sv -work $SIM_LIB +incdir+../src ../src/signal_detection/signal_edge_detector.v ../src/system/sys_ticker.v
vlog -sv -work $SIM_LIB ../src/drivers/i2s_driver.v ../src/drivers/lcd_sdp_ram.v
do do/common/compile_lcd_spectrum.do
vlog -sv -work $SIM_LIB ../src/lcd_ui/lcd_pcm_capture.v ../src/lcd_ui/lcd_waveform_builder.v ../src/lcd_ui/ui_interaction.v
vlog -sv -work $SIM_LIB tb/lcd_ui/ui_audio_receive_tb.vt
vsim -L gw5a -t 1ps -onfinish stop -gSPECTRUM_TEST=1 -wlf lcd_ui/results/spectrum_i2s.wlf $SIM_LIB.ui_audio_receive_tb
run -all
if {[examine -radix unsigned sim:/ui_audio_receive_tb/test_passed]!=1} {quit -code 1 -force}
quit -sim
vsim -L gw5a -t 1ps -onfinish stop -gSPECTRUM_TEST=1 -gUSE_REAL_TICKER=1 -gLONG_STALL=0 -wlf lcd_ui/results/spectrum_i2s_real.wlf $SIM_LIB.ui_audio_receive_tb
run -all
if {[examine -radix unsigned sim:/ui_audio_receive_tb/test_passed]!=1} {quit -code 1 -force}
echo SPECTRUM_I2S_SUITE_PASS
quit -code 0 -force
