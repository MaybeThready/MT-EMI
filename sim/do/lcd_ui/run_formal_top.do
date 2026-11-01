# 从正式根目录GPRJ编译完整整机，运行真实UI、音频链与LCD绘图联合仿真。
# 仿真DO文件从正式sim目录执行；实现TCL由用户在工具中自行运行。
onerror {quit -code 1 -force}
onbreak {resume}
do do/common/setup_gowin.do
set SIM_LIB work_lcd_formal_top
do do/common/setup.do
file mkdir lcd_ui/results
set fd [open ../MT-EMI.gprj r]
set xml [read $fd]
close $fd
foreach line [split $xml \n] {
    if {[regexp {File path="([^"]+\.v)" type="file.verilog" enable="1"} $line -> source]} {
        if {$source ne "src/adsr_division/adsr_division.v"} {
            vlog -sv -work $SIM_LIB +incdir+../src ../$source
        }
    }
}
vlog -sv -work $SIM_LIB tb/audio/adsr_division_functional.vt tb/lcd_ui/lcd_formal_top_tb.vt
vsim -L gw5a -t 1ps -onfinish stop -wlf lcd_ui/results/formal_top.wlf $SIM_LIB.lcd_formal_top_tb
run -all
if {[examine -radix unsigned sim:/lcd_formal_top_tb/test_passed] != 1} {quit -code 1 -force}
echo LCD_FORMAL_PROJECT_PASS
quit -code 0 -force
