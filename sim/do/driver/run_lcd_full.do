# Full native raster, every panel-sampled pixel, three changing scenes.
onerror {quit -code 1 -force}
onbreak {resume}
do do/common/setup_gowin.do
set SIM_LIB work_lcd_stream_full
do do/common/setup.do
file mkdir drivers/results/lcd_stream
vlog -sv -work $SIM_LIB ../src/common/fsm.v ../src/drivers/lcd_sdp_ram.v ../src/drivers/lcd_font_rom.v ../src/drivers/lcd_palette.v ../src/drivers/lcd_scene.v ../src/drivers/lcd_driver.v tb/drivers/lcd_driver_tb.vt
vsim -t 1ps -onfinish stop -L gw5a -wlf drivers/results/lcd_stream/full.wlf -gH_ACTIVE=800 -gV_ACTIVE=480 -gH_BACK=182 -gH_FRONT=210 -gV_BACK=8 -gV_FRONT=45 $SIM_LIB.lcd_driver_tb +PPM=drivers/results/lcd_stream/wave_frame.ppm
run -all
if {[examine -radix unsigned sim:/lcd_driver_tb/test_passed] != 1} {quit -code 1 -force}
echo LCD_STREAM_FULL_PASS
quit -code 0 -force
