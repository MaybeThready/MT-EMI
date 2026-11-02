# 正式整机联合长测；真实PCM/FFT/I2S及最新和弦，保留2048周期采样tick。
# 已核验的同步存储模型仅用于仿真；综合GPRJ仍使用原厂IP与INIT_RAM。
onerror {quit -code 1 -force}
onbreak {}
set LCD_V4_CASE system
if {![info exists MT_ROOT] || (![file exists [file join $MT_ROOT MT-EMI.gprj]] || ![file exists [file join $MT_ROOT sim do lcd_ui v4_common.do]])} {
    set MT_ROOT [file normalize [pwd]]
    while {(![file exists [file join $MT_ROOT MT-EMI.gprj]] || ![file exists [file join $MT_ROOT sim do lcd_ui v4_common.do]]) && [file dirname $MT_ROOT] ne $MT_ROOT} {
        set MT_ROOT [file dirname $MT_ROOT]
    }
    if {(![file exists [file join $MT_ROOT MT-EMI.gprj]] || ![file exists [file join $MT_ROOT sim do lcd_ui v4_common.do]])} {error "Run LCD simulation from this repository or its ai_workspace"}
}
do [file join $MT_ROOT sim do lcd_ui v4_common.do]
lcd_v4_library work
set CHORD_REAL_PLL 0
do do/common/compile_chord_system.do
lcd_v4_test chord_system_tb -gUSE_REAL_PLL=0 -gFULL_WINDOWS=1
echo LCD_V4_FORMAL_SYSTEM_PASS
if {![info exists LCD_V4_SUITE]} {quit -code 0 -force}
