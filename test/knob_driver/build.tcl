# Run with gw_sh build.tcl. Shared paths are relative to this project directory.
cd [file dirname [file normalize [info script]]]
open_project test_knob_driver.gprj
set_option -top_module test_knob_driver
set_option -verilog_std sysv2017
set_option -include_path {../../src/system}
set_option -timing_driven 1
set_option -place_option 3
set_option -route_option 2
set build_start [clock seconds]
run all
if {![file isfile impl/pnr/test_knob_driver.fs] || [file mtime impl/pnr/test_knob_driver.fs] < $build_start} {
    error {No new knob bitstream was generated; do not download an old pnr file.}
}
