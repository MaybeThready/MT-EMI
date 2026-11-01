# V3原生800×480光栅回归，逐像素检查三次场景变化及首/中/末字形银行。
# 仿真DO文件从正式sim目录执行；实现TCL由用户在工具中自行运行。
onerror {quit -code 1 -force}
onbreak {resume}
do do/common/setup_gowin.do
set SIM_LIB work_lcd_stream_full
do do/common/setup.do
file mkdir drivers/results/lcd_stream
vlog -sv -work $SIM_LIB ../src/common/fsm.v ../src/drivers/lcd_sdp_ram.v ../src/lcd_ui/lcd_tile_rom.v ../src/drivers/lcd_palette.v ../src/drivers/lcd_scene.v ../src/drivers/lcd_driver.v tb/drivers/lcd_driver_tb.vt
vsim -t 1ps -onfinish stop -L gw5a -wlf drivers/results/lcd_stream/full.wlf -gH_ACTIVE=800 -gV_ACTIVE=480 -gH_BACK=182 -gH_FRONT=210 -gV_BACK=8 -gV_FRONT=45 $SIM_LIB.lcd_driver_tb +PPM=drivers/results/lcd_stream/wave_frame.ppm
run -all
if {[examine -radix unsigned sim:/lcd_driver_tb/test_passed] != 1} {quit -code 1 -force}
echo LCD_V3_FULL_PASS
quit -code 0 -force
