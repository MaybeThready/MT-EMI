onerror {quit -code 1 -force}
onbreak {resume}
set LCD_V4_CASE autoplay_tiles
do do/lcd_ui/v4_common.do
lcd_v4_library work
lcd_v4_fast_lcd
lcd_v4_vlog tb/lcd_ui/lcd_autoplay_tiles_tb.vt
lcd_v4_test lcd_autoplay_tiles_tb
echo LCD_AUTOPLAY_TILES_SUITE_PASS
quit -code 0 -force
