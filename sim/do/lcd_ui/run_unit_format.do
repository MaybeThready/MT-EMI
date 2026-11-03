# From sim/: do do/lcd_ui/run_unit_format.do
onerror {quit -code 1 -force}
onbreak {resume}
set LCD_V4_CASE unit_format
do do/lcd_ui/v4_common.do
lcd_v4_library work
lcd_v4_fast_lcd
lcd_v4_vlog tb/lcd_ui/lcd_unit_format_tb.vt
lcd_v4_test lcd_unit_format_tb
echo LCD_UNIT_FORMAT_SUITE_PASS
quit -code 0 -force
