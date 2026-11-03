# 从sim/执行。复用正式工程文件列表，仿真模型不进入综合工程。
do do/common/setup_gowin.do
set sources {}
set fd [open ../MT-EMI.gprj r]
set project_text [read $fd]
close $fd
foreach line [split $project_text \n] {
    if {[regexp {File path="([^"]+\.v)" type="file.verilog" enable="1"} $line -> source]} {
        set name [file tail $source]
        if {$name ni {adsr_division.v rom_wavetables.v audio_mix_buffer.v lcd_tile_rom.v lcd_text_rom.v lcd_glyph_rom.v lcd_fft_coeff_rom.v lcd_sdp_ram.v}} {
            lappend sources ../$source
        }
    }
}
vlog -modelsimini $::env(MODELSIM) -sv -work $SIM_LIB +incdir+../src +incdir+../src/audio {*}$sources \
    tb/models/adsr_division_model.vt tb/models/adclrc_model.vt \
    tb/audio/memory_functional.vt tb/audio/memory_ip_aliases.vt \
    tb/lcd_ui/lcd_memory_models.vt tb/lcd_ui/lcd_memory_aliases.vt \
    tb/drivers/spi_nor_model.vt tb/test/test_full_system_tb.vt tb/test/test_full_system_inputs_tb.vt
