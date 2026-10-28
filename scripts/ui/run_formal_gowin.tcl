# 从脚本所在项目根目录打开工程，复现 UI v2 诊断顶层的实现选项。
# 沿用第二轮 +0.059 ns 的实现选项；源码改动的结果须重新实测。
set repo_dir [file normalize [file join [file dirname [info script]] ../..]]
cd $repo_dir
open_project MT-EMI.gprj
set_option -top_module top
set_option -verilog_std sysv2017
set_option -timing_driven 1
set_option -show_all_warn 1
set_option -oreg_in_iob 0
# 第二轮配置：扇出 1000、布局 3、布线 2、不复制资源；不放宽 SDC。
set_option -max_fanout 1000
set_option -place_option 3
set_option -route_option 2
set_option -replicate_resources 0
run all
exit
