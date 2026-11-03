onerror {quit -code 1 -force}
onbreak {resume}
set LCD_V4_CASE autoplay_memory
do do/lcd_ui/v4_common.do
lcd_v4_library memory
lcd_v4_vlog ../src/drivers/lcd_sdp_ram.v ../src/lcd_ui/lcd_fft_coeff_rom.v ../src/lcd_ui/lcd_tile_rom.v ../src/lcd_ui/lcd_text_rom.v ../src/lcd_ui/lcd_glyph_rom.v
lcd_v4_vlog tb/lcd_ui/lcd_memory_models.vt tb/lcd_ui/lcd_chord_memory_tb.vt
lcd_v4_test lcd_chord_memory_tb
echo LCD_AUTOPLAY_MEMORY_SUITE_PASS
quit -code 0 -force
