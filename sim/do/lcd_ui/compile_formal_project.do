# 从正式sim目录打开并编译ModelSim工程，检查MPF依赖完整。
# 仿真DO文件从正式sim目录执行；实现TCL由用户在工具中自行运行。
onerror {quit -code 1 -force}
do do/common/setup_gowin.do
if {![file isdirectory work]} {vlib work}
project open MT-EMI
project compileall
echo LCD_FORMAL_MPF_COMPILE_PASS
project close
quit -code 0 -force
