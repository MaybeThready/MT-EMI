# Optional IP-model equivalence check. Run from sim/; expect 298 matching results.
onerror {abort all}
set SIM_LIB work_test_velocity_divider
do do/common/setup.do
set GOWIN_SIM_LIB gw5a
if {[catch {vmap $GOWIN_SIM_LIB}]} {
    set primitive_file {}
    if {[info exists env(GOWIN_HOME)]} {
        foreach relative_path {simlib/gw5a/prim_sim.v IDE/simlib/gw5a/prim_sim.v} {
            set candidate [file join $env(GOWIN_HOME) $relative_path]
            if {[file isfile $candidate]} {set primitive_file $candidate; break}
        }
    }
    if {$primitive_file eq {}} {error {Map gw5a or set GOWIN_HOME to the Gowin IDE/install directory.}}
    set GOWIN_SIM_LIB ${SIM_LIB}_gw5a
    if {[file isdirectory $GOWIN_SIM_LIB]} {vdel -lib $GOWIN_SIM_LIB -all}
    vlib $GOWIN_SIM_LIB
    vlog -work $GOWIN_SIM_LIB $primitive_file
}
# Rename only the simulation copy, so the original IP and its model can coexist.
quietly set input_file [open tb/models/adsr_division_model.vt r]
fconfigure $input_file -encoding utf-8
quietly set reference_source [string map {"module adsr_division\n" "module adsr_division_reference\n"} [read $input_file]]
close $input_file
quietly set output_file [open $SIM_LIB/adsr_division_reference.vt w]
fconfigure $output_file -encoding utf-8
puts $output_file $reference_source
close $output_file
vlog -work $SIM_LIB ../src/adsr_division/adsr_division.vo
vlog -sv -work $SIM_LIB $SIM_LIB/adsr_division_reference.vt tb/test/test_velocity_divider_tb.vt
vsim -t 1ps -L $GOWIN_SIM_LIB -onfinish stop -wlf $SIM_LIB/test_velocity_divider_tb.wlf $SIM_LIB.test_velocity_divider_tb
run -all
