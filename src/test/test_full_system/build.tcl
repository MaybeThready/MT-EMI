# 从根工程生成隔离的本地实现配置；不更改根工程原有顶层/约束选择。
# 共享源码及CST/SDC在src/test；生成工程和实现结果只写ai_workspace。
set repo_dir [file normalize [file join [file dirname [info script]] ../../..]]
set build_dir [file join $repo_dir ai_workspace full_system_build]
file mkdir $build_dir
set fd [open [file join $repo_dir MT-EMI.gprj] r]
set project [read $fd]
close $fd
set lines {}
foreach line [split $project \n] {
    if {[regexp {<File path="([^"]+)" type="([^"]+)" enable="([01])"/>} $line -> path kind enable]} {
        if {$kind eq "file.cst" || $kind eq "file.sdc"} {
            set enable [expr {[string match "src/test/test_full_system/*" $path] ? 1 : 0}]
        }
        set line "        <File path=\"../../$path\" type=\"$kind\" enable=\"$enable\"/>"
    }
    lappend lines $line
}
set fd [open [file join $build_dir test_full_system.gprj] w]
puts $fd [join $lines \n]
close $fd
cd $build_dir
open_project test_full_system.gprj
set_option -top_module test_full_system
set_option -verilog_std sysv2017
set_option -include_path [list [file join $repo_dir src] [file join $repo_dir src audio]]
set_option -timing_driven 1
set_option -show_all_warn 1
set_option -oreg_in_iob 0
set_option -max_fanout 1000
set_option -place_option 3
set_option -route_option 2
set_option -replicate_resources 0
set build_started [clock seconds]
run all
set result [file join $build_dir impl pnr test_full_system.fs]
if {![file exists $result] || [file mtime $result] < $build_started} {
    error "No fresh full-system bitstream was produced; inspect the implementation log."
}
set timing_file [file join $build_dir impl pnr test_full_system.tr]
set fd [open $timing_file r]
set timing [read $fd]
close $fd
if {![regexp {<Numbers of Setup Violated Endpoints>:([0-9]+)} $timing -> setup_violations] ||
    ![regexp {<Numbers of Hold Violated Endpoints>:([0-9]+)} $timing -> hold_violations]} {
    error "Cannot confirm timing status; inspect $timing_file"
}
set negative_slack 0
set reported_slacks [regexp -all -inline {Slack\s*:\s*(-?[0-9]+\.[0-9]+)} $timing]
if {[llength $reported_slacks] == 0} {error "No detailed path slacks found in $timing_file"}
foreach {entry slack} $reported_slacks {
    if {$slack < 0} {set negative_slack 1}
}
if {$setup_violations != 0 || $hold_violations != 0 || $negative_slack} {
    puts "FULL_SYSTEM_TIMING_NOT_MET setup=$setup_violations hold=$hold_violations"
    error "Bitstream exists, but timing is not closed. Do not treat it as an accepted board build: $timing_file"
}
puts "FULL_SYSTEM_BITSTREAM $result"
exit
