# From sim/: do do/test/run_test_ui.do
# All generated libraries and waveforms stay in ai_workspace.
onerror {abort all}
set SIM_LIB ../ai_workspace/test_ui_sim/work
file mkdir ../ai_workspace/test_ui_sim
if {![file isdirectory $SIM_LIB]} {vlib $SIM_LIB}

set primitive ""
if {[info exists ::env(GOWIN_PRIM_SIM)]} {set primitive $::env(GOWIN_PRIM_SIM)}
if {$primitive eq "" && [info exists ::env(GOWIN_HOME)]} {
    set candidate [file join $::env(GOWIN_HOME) IDE/simlib/gw5a/prim_sim.v]
    if {[file exists $candidate]} {set primitive $candidate}
}
if {$primitive eq ""} {
    foreach root {D:/Software/Gowin C:/Gowin D:/Gowin} {
        foreach candidate [lsort -decreasing [glob -nocomplain $root/*/IDE/simlib/gw5a/prim_sim.v]] {
            set primitive $candidate
            break
        }
        if {$primitive ne ""} {break}
    }
}
if {![file exists $primitive]} {error "Set GOWIN_PRIM_SIM to GW5A prim_sim.v"}

set fd [open ../MT-EMI.gprj r]
quietly set project_text [read $fd]
close $fd
set sources [list]
foreach line [split $project_text \n] {
    if {[regexp {File path="([^"]+\.v)" type="file.verilog" enable="1"} $line -> source]} {
        if {$source ne "src/adsr_division/adsr_division.v"} {lappend sources ../$source}
    }
}
vlog -quiet -sv -work $SIM_LIB +incdir+../src $primitive tb/audio/adsr_division_functional.vt {*}$sources tb/test/test_ui_tb.vt
vsim -t 1ps -voptargs=+acc -onfinish stop -wlf ../ai_workspace/test_ui_sim/test_ui.wlf -lib $SIM_LIB test_ui_tb
do do/test/wave_test_ui.do
run -all
