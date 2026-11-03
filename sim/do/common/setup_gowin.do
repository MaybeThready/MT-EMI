# 原厂GW5A仿真库只编译到ai_workspace，源文件来自用户安装的EDA。
do do/common/output_paths.do
set GOWIN_SIM_LIB [file join $MT_AI sim vendor gw5a]
file mkdir [file dirname $GOWIN_SIM_LIB]
if {![file isdirectory $GOWIN_SIM_LIB]} {
    set primitive ""
    if {[info exists ::env(GOWIN_PRIM_SIM)]} {set primitive $::env(GOWIN_PRIM_SIM)}
    if {$primitive eq "" && [info exists ::env(GOWIN_HOME)]} {
        foreach suffix {IDE/simlib/gw5a/prim_sim.v simlib/gw5a/prim_sim.v} {
            set candidate [file join $::env(GOWIN_HOME) $suffix]
            if {[file exists $candidate]} {set primitive $candidate; break}
        }
    }
    if {$primitive eq ""} {
        foreach root {C:/Gowin D:/Gowin} {
            foreach candidate [lsort -decreasing [glob -nocomplain $root/*/IDE/simlib/gw5a/prim_sim.v]] {
                set primitive $candidate
                break
            }
            if {$primitive ne ""} {break}
        }
    }
    if {![file exists $primitive]} {error "Set GOWIN_PRIM_SIM or GOWIN_HOME to installed GW5A prim_sim.v"}
    vlib $GOWIN_SIM_LIB
    vlog -modelsimini $::env(MODELSIM) -work $GOWIN_SIM_LIB $primitive
}
vmap -modelsimini $::env(MODELSIM) gw5a $GOWIN_SIM_LIB
