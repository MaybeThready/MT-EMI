# 正式第四版单元与原生RGB回归；无需Python/TTF，结果仅在ai_workspace。
onerror {quit -code 1 -force}
onbreak {}
set LCD_V4_CASE units
if {![info exists MT_ROOT] || (![file exists [file join $MT_ROOT MT-EMI.gprj]] || ![file exists [file join $MT_ROOT sim do lcd_ui v4_common.do]])} {
    set MT_ROOT [file normalize [pwd]]
    while {(![file exists [file join $MT_ROOT MT-EMI.gprj]] || ![file exists [file join $MT_ROOT sim do lcd_ui v4_common.do]]) && [file dirname $MT_ROOT] ne $MT_ROOT} {
        set MT_ROOT [file dirname $MT_ROOT]
    }
    if {(![file exists [file join $MT_ROOT MT-EMI.gprj]] || ![file exists [file join $MT_ROOT sim do lcd_ui v4_common.do]])} {error "Run LCD simulation from this repository or its ai_workspace"}
}
do [file join $MT_ROOT sim do lcd_ui v4_common.do]
lcd_v4_library memory
lcd_v4_vlog ../src/drivers/lcd_sdp_ram.v ../src/lcd_ui/lcd_fft_coeff_rom.v ../src/lcd_ui/lcd_tile_rom.v ../src/lcd_ui/lcd_text_rom.v ../src/lcd_ui/lcd_glyph_rom.v
lcd_v4_vlog tb/lcd_ui/lcd_memory_models.vt tb/lcd_ui/lcd_chord_memory_tb.vt
lcd_v4_test lcd_chord_memory_tb
lcd_v4_library work
lcd_v4_fast_lcd
lcd_v4_vlog tb/lcd_ui/lcd_decimal_tb.vt tb/lcd_ui/drawers_tb.vt tb/lcd_ui/lcd_scene_motion_tb.vt tb/lcd_ui/lcd_v4_native_tb.vt
lcd_v4_vlog tb/lcd_ui/lcd_waveform_builder_tb.vt tb/lcd_ui/lcd_spectrum_builder_tb.vt tb/drivers/lcd_configuration_tb.vt
foreach test {lcd_decimal_tb drawers_tb lcd_scene_motion_tb lcd_waveform_builder_tb lcd_spectrum_builder_tb lcd_configuration_tb lcd_v4_native_tb} {lcd_v4_test $test}
echo LCD_V4_FORMAL_UNITS_PASS
if {![info exists LCD_V4_SUITE]} {quit -code 0 -force}
