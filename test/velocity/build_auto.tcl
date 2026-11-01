# Independent build directory: never overwrite the real-keyboard project's pnr output.
set project_dir [file dirname [file normalize [info script]]]
cd $project_dir
set input_file [open test_velocity.gprj r]
set project_xml [read $input_file]
close $input_file
# The generated project is two levels below the original; its paths stay relative.
set project_xml [string map [list {path="} {path="../../}] $project_xml]
file mkdir impl/auto_build
set output_file [open impl/auto_build/test_velocity_auto.gprj w]
puts $output_file $project_xml
close $output_file
cd impl/auto_build
open_project test_velocity_auto.gprj
set_option -top_module test_velocity_auto
set_option -verilog_std sysv2017
set_option -include_path {../../../../src/audio}
set_option -timing_driven 1
set_option -place_option 3
set_option -route_option 2
set_option -replicate_resources 0
set_option -retiming_resource none
set build_start [clock seconds]
run all
if {![file isfile impl/pnr/test_velocity_auto.fs] || [file mtime impl/pnr/test_velocity_auto.fs] < $build_start} {
    error {No new auto diagnostic bitstream was generated; do not use an old pnr file.}
}
set result_dir [file join $project_dir impl auto]
file mkdir $result_dir
file copy -force impl/pnr/test_velocity_auto.fs [file join $result_dir test_velocity_auto.fs]
file copy -force impl/pnr/test_velocity_auto.tr [file join $result_dir test_velocity_auto.tr]
