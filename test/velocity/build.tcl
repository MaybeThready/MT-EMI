# Run using gw_sh build.tcl; all shared project paths are relative.
cd [file dirname [info script]]
open_project test_velocity.gprj
set_option -top_module test_velocity
set_option -verilog_std sysv2017
set_option -include_path {../../src/audio}
set_option -timing_driven 1
set_option -place_option 3
set_option -route_option 2
set_option -replicate_resources 0
set_option -retiming_resource none
set build_start [clock seconds]
run all
if {![file isfile impl/pnr/test_velocity.fs] || [file mtime impl/pnr/test_velocity.fs] < $build_start} {
    error {No new keyboard bitstream was generated; do not use an old pnr file.}
}
file mkdir impl/keyboard
file copy -force impl/pnr/test_velocity.fs impl/keyboard/test_velocity.fs
file copy -force impl/pnr/test_velocity.tr impl/keyboard/test_velocity.tr
