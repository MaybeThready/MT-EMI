# 第四版正式回归辅助；输入只来自src/sim/assets，输出只进入ai_workspace。
if {![info exists MT_ROOT] || (![file exists [file join $MT_ROOT MT-EMI.gprj]] || ![file exists [file join $MT_ROOT sim do lcd_ui v4_common.do]])} {
    set MT_ROOT [file normalize [pwd]]
    while {(![file exists [file join $MT_ROOT MT-EMI.gprj]] || ![file exists [file join $MT_ROOT sim do lcd_ui v4_common.do]]) && [file dirname $MT_ROOT] ne $MT_ROOT} {
        set MT_ROOT [file dirname $MT_ROOT]
    }
    if {(![file exists [file join $MT_ROOT MT-EMI.gprj]] || ![file exists [file join $MT_ROOT sim do lcd_ui v4_common.do]])} {error "Run LCD simulation from this repository or its ai_workspace"}
}

unset -nocomplain MT_LOG_TARGET
set MT_RUN_NAME lcd_v4_${LCD_V4_CASE}
do [file join $MT_ROOT sim do common output_paths.do]
set LCD_V4_OUT [file join $MT_AI sim lcd_v4 $LCD_V4_CASE]
set LCD_V4_RESULTS [file join $LCD_V4_OUT results]
file mkdir $LCD_V4_RESULTS
set MT_LOG_TARGET [file join $LCD_V4_OUT run.log]
transcript file $MT_LOG_TARGET
transcript on
cd [file join $MT_ROOT sim]
do do/common/setup_gowin.do
set MT_LOG_TARGET [file join $LCD_V4_OUT run.log]
transcript file $MT_LOG_TARGET
proc lcd_v4_library {name} {
    global SIM_LIB LCD_V4_OUT
    catch {quit -sim}
    set SIM_LIB [file join $LCD_V4_OUT $name]
    if {[file isdirectory $SIM_LIB]} {vdel -lib $SIM_LIB -all}
    vlib $SIM_LIB
}
proc lcd_v4_vlog {args} {
    global SIM_LIB env
    eval vlog -modelsimini [list $env(MODELSIM)] -sv -work [list $SIM_LIB] $args
}
proc lcd_v4_fast_lcd {} {
    foreach source [glob ../src/lcd_ui/*.v] {
        if {[file tail $source] ni {lcd_tile_rom.v lcd_text_rom.v lcd_glyph_rom.v lcd_fft_coeff_rom.v}} {lcd_v4_vlog $source}
    }
    foreach name {lcd_driver lcd_scene lcd_palette} {lcd_v4_vlog ../src/drivers/${name}.v}
    lcd_v4_vlog ../src/common/fsm.v tb/lcd_ui/lcd_memory_models.vt tb/lcd_ui/lcd_memory_aliases.vt
}
proc lcd_v4_test {name args} {
    global SIM_LIB LCD_V4_RESULTS
    eval vsim -L gw5a -t 1ps -onfinish stop -voptargs=+acc -wlf [list [file join $LCD_V4_RESULTS ${name}.wlf]] [list $SIM_LIB.$name] [list +RESULTS=$LCD_V4_RESULTS] $args
    run -all
    if {[examine -radix unsigned sim:/$name/test_passed]!=1} {error "FAILED: $name"}
    quit -sim
}
