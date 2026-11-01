# User-run implementation entry. Not executed during delivery verification.
set repo_dir [file normalize [file join [file dirname [info script]] ../..]]
cd $repo_dir
open_project MT-EMI.gprj
set_option -top_module top
set_option -verilog_std sysv2017
set_option -timing_driven 1
set_option -show_all_warn 1
run all
exit
