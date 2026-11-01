# 当前V3驱动回归：真实SDP、调色板、配置拒绝、场景动画及逐像素扫描。
# 仿真DO文件从正式sim目录执行；实现TCL由用户在工具中自行运行。
onerror {quit -code 1 -force}
onbreak {resume}
do do/common/setup_gowin.do
set SIM_LIB work_lcd_delivery
do do/common/setup.do
file mkdir drivers/results/lcd_delivery
vlog -sv -work $SIM_LIB ../src/common/fsm.v ../src/drivers/lcd_sdp_ram.v ../src/lcd_ui/lcd_tile_rom.v ../src/drivers/lcd_palette.v ../src/drivers/lcd_scene.v ../src/drivers/lcd_driver.v
vlog -sv -work $SIM_LIB tb/drivers/lcd_sdp_ram_tb.vt tb/lcd_ui/lcd_scene_motion_tb.vt tb/drivers/lcd_palette_tb.vt tb/drivers/lcd_driver_tb.vt tb/drivers/lcd_configuration_tb.vt
foreach tb {lcd_scene_motion_tb lcd_palette_tb lcd_configuration_tb} {
    vsim -L gw5a -t 1ps -onfinish stop -wlf drivers/results/lcd_delivery/${tb}.wlf $SIM_LIB.$tb
    run -all
    if {[examine -radix unsigned sim:/$tb/test_passed] != 1} {quit -code 1 -force}
    quit -sim
}
foreach width {16 32} {
    vsim -L gw5a -t 1ps -onfinish stop -gDATA_WIDTH=$width -wlf drivers/results/lcd_delivery/ram${width}.wlf $SIM_LIB.lcd_sdp_ram_tb
    run -all
    if {[examine -radix unsigned sim:/lcd_sdp_ram_tb/test_passed] != 1} {quit -code 1 -force}
    quit -sim
}
foreach div {2 4 6} {
    vsim -L gw5a -t 1ps -onfinish stop -gPIXEL_DIV=$div -wlf drivers/results/lcd_delivery/div${div}.wlf $SIM_LIB.lcd_driver_tb
    run -all
    if {[examine -radix unsigned sim:/lcd_driver_tb/test_passed] != 1} {quit -code 1 -force}
    quit -sim
}
echo LCD_V3_DRIVER_SUITE_PASS
quit -code 0 -force
