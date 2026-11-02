# 保持独立工作库，所有生成目录统一约束在ai_workspace中。
do do/common/output_paths.do
catch {quit -sim}
if {[file pathtype $SIM_LIB] ne "absolute"} {
    if {[string match "../ai_workspace/*" $SIM_LIB]} {
        set SIM_LIB [file normalize [file join $MT_ROOT sim $SIM_LIB]]
    } else {
        set SIM_LIB [file normalize [file join $MT_AI sim libraries $SIM_LIB]]
    }
}
set allowed_prefix "[file normalize $MT_AI]/"
if {![string equal -nocase $allowed_prefix [string range [file normalize $SIM_LIB] 0 [expr {[string length $allowed_prefix]-1}]]]} {
    error "Simulation library must remain in ai_workspace: $SIM_LIB"
}
file mkdir [file dirname $SIM_LIB]
if {[file isdirectory $SIM_LIB]} {vdel -lib $SIM_LIB -all}
vlib $SIM_LIB
