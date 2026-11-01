# Run from sim/. Vendor installation is external; design inputs stay relative.
# Set GOWIN_PRIM_SIM to a prim_sim.v, or GOWIN_HOME to the EDA installation.
# Compiled vendor models are generated locally, never copied from ai_workspace.
if {![file exists modelsim.ini]} {vmap -c}
file mkdir vendor
if {![file isdirectory vendor/gw5a]} {
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
    if {![file exists $primitive]} {
        error "Set GOWIN_PRIM_SIM or GOWIN_HOME to the installed GW5A simulation library."
    }
    vlib vendor/gw5a
    vlog -work vendor/gw5a $primitive
}
quietly set map_fd [open modelsim.ini r]
quietly set map_text [read $map_fd]
close $map_fd
if {![regexp {gw5a\s*=\s*vendor/gw5a} $map_text]} {vmap gw5a vendor/gw5a}
