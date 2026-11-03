# Compile actual formal connectivity; clock/IP models are simulation-only.
do do/common/setup_gowin.do
do do/common/compile_chord_audio.do
foreach source [glob ../src/lcd_ui/*.v] {
    if {[file tail $source] ni {lcd_tile_rom.v lcd_text_rom.v lcd_glyph_rom.v lcd_fft_coeff_rom.v}} {vlog -sv -work $SIM_LIB $source}
}
foreach name {lcd_driver lcd_scene lcd_palette keyboard_driver keyboard_adc keyboard_pressure_scanner knob_driver button_driver pitch_bend_driver shared_adc_manager i2s_driver preset_storage_driver spi_nor_flash spi_nor_transfer} {
    vlog -sv -work $SIM_LIB ../src/drivers/${name}.v
}
vlog -sv -work $SIM_LIB ../src/system/ui_peripheral_bridge.v ../src/system/audio_parameter_bridge.v
vlog -sv -work $SIM_LIB ../src/system/autoplay_event_rom.v ../src/system/autoplay_frequency_lut.v ../src/system/autoplay_player.v
if {$CHORD_REAL_PLL} {
    vlog -sv -work $SIM_LIB ../src/system/sys_clocker.v ../src/pll_init.v ../src/gowin_pll/gowin_pll.v ../src/gowin_pll/gowin_pll_mod.v
} else {
    vlog -sv -work $SIM_LIB tb/system/chord_clock_model.vt
}
vlog -sv -work $SIM_LIB tb/lcd_ui/lcd_memory_models.vt tb/lcd_ui/lcd_memory_aliases.vt
vlog -sv -work $SIM_LIB tb/models/adclrc_model.vt
vlog -sv -work $SIM_LIB ../src/top.v tb/drivers/spi_nor_model.vt tb/lcd_ui/chord_system_tb.vt
