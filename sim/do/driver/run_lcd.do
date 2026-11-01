# Current compact-scene driver only. No old board top or demo pattern source.
onerror {quit -code 1 -force}
onbreak {resume}
do do/common/setup_gowin.do
set SIM_LIB work_lcd_delivery
do do/common/setup.do
file mkdir drivers/results/lcd_delivery
vlog -sv -work $SIM_LIB ../src/common/fsm.v ../src/drivers/lcd_sdp_ram.v ../src/drivers/lcd_font_rom.v ../src/drivers/lcd_palette.v ../src/drivers/lcd_scene.v ../src/drivers/lcd_driver.v
vlog -sv -work $SIM_LIB tb/drivers/lcd_sdp_ram_tb.vt tb/drivers/lcd_font_rom_tb.vt tb/drivers/lcd_scene_tb.vt tb/drivers/lcd_palette_tb.vt tb/drivers/lcd_driver_tb.vt tb/drivers/lcd_configuration_tb.vt
foreach tb {lcd_font_rom_tb lcd_scene_tb lcd_palette_tb lcd_configuration_tb} {
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
echo LCD_FORMAL_DRIVER_PASS
quit -code 0 -force
