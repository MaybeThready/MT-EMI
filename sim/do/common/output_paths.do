# 统一仿真产物目录；可从正式sim目录调用，不向正式目录写日志/编译库。
if {![info exists MT_ROOT] || (![file exists [file join $MT_ROOT MT-EMI.gprj]] || ![file exists [file join $MT_ROOT sim do lcd_ui v4_common.do]])} {
    set MT_ROOT [file normalize [pwd]]
    while {(![file exists [file join $MT_ROOT MT-EMI.gprj]] || ![file exists [file join $MT_ROOT sim do lcd_ui v4_common.do]]) && [file dirname $MT_ROOT] ne $MT_ROOT} {
        set MT_ROOT [file dirname $MT_ROOT]
    }
    if {(![file exists [file join $MT_ROOT MT-EMI.gprj]] || ![file exists [file join $MT_ROOT sim do lcd_ui v4_common.do]])} {error "Run LCD simulation from this repository or its ai_workspace"}
}
if {(![file exists [file join $MT_ROOT MT-EMI.gprj]] || ![file exists [file join $MT_ROOT sim do lcd_ui v4_common.do]])} {error "Cannot locate MT-EMI root: $MT_ROOT"}
set MT_AI [file join $MT_ROOT ai_workspace]
set LCD_RESULTS [file join $MT_AI sim lcd_ui results]
set DRIVER_RESULTS [file join $MT_AI sim drivers results]
set MT_MODEL_DIR [file join $MT_AI sim modelsim]
foreach directory [list $LCD_RESULTS $DRIVER_RESULTS $MT_MODEL_DIR] {file mkdir $directory}
set MT_INI [file join $MT_MODEL_DIR modelsim.ini]
if {![file exists $MT_INI]} {
    set saved_directory [pwd]
    cd $MT_MODEL_DIR
    unset -nocomplain ::env(MODELSIM)
    vmap -c
    cd $saved_directory
}
set ::env(MODELSIM) $MT_INI
if {![info exists MT_RUN_NAME]} {set MT_RUN_NAME formal_simulation}
set MT_LOG_DIR [file join $MT_AI sim logs]
file mkdir $MT_LOG_DIR
if {[info exists MT_LOG_TARGET]} {
    transcript file $MT_LOG_TARGET
} else {
    transcript file [file join $MT_LOG_DIR ${MT_RUN_NAME}.log]
}
transcript on
