# 第四版正式移交回归总入口，不运行综合或布局布线。
onerror {quit -code 1 -force}
onbreak {}
set LCD_V4_SUITE 1
if {![info exists MT_ROOT] || (![file exists [file join $MT_ROOT MT-EMI.gprj]] || ![file exists [file join $MT_ROOT sim do lcd_ui v4_common.do]])} {
    set MT_ROOT [file normalize [pwd]]
    while {(![file exists [file join $MT_ROOT MT-EMI.gprj]] || ![file exists [file join $MT_ROOT sim do lcd_ui v4_common.do]]) && [file dirname $MT_ROOT] ne $MT_ROOT} {
        set MT_ROOT [file dirname $MT_ROOT]
    }
    if {(![file exists [file join $MT_ROOT MT-EMI.gprj]] || ![file exists [file join $MT_ROOT sim do lcd_ui v4_common.do]])} {error "Run LCD simulation from this repository or its ai_workspace"}
}
set LCD_V4_ENTRY [file join $MT_ROOT sim do lcd_ui]
do [file join $LCD_V4_ENTRY run_v4_units.do]
do [file join $LCD_V4_ENTRY run_v4_system.do]
echo LCD_V4_FORMAL_SUITE_PASS
quit -code 0 -force
