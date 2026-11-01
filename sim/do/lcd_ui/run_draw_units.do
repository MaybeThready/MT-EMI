# 正式LCD绘图回归，覆盖BCD、场景动画、44页绘图字及背压/复位。
# RTL取自正式GPRJ的启用文件，不依赖ai_workspace。
# 仿真DO文件从正式sim目录执行；实现TCL由用户在工具中自行运行。
onerror {quit -code 1 -force}
onbreak {resume}
do do/common/setup_gowin.do
set SIM_LIB work_lcd_draw_units
do do/common/setup.do
file mkdir lcd_ui/results
set fd [open ../MT-EMI.gprj r]
set xml [read $fd]
close $fd
foreach line [split $xml \n] {
    if {[regexp {File path="([^"]+\.v)" type="file.verilog" enable="1"} $line -> source]} {
        if {$source eq "src/common/fsm.v" || [string match "src/lcd_ui/*" $source] || [string match "src/drivers/lcd_*" $source]} {
            vlog -sv -work $SIM_LIB ../$source
        }
    }
}
vlog -sv -work $SIM_LIB tb/lcd_ui/lcd_decimal_tb.vt tb/lcd_ui/lcd_scene_motion_tb.vt tb/lcd_ui/drawers_tb.vt
foreach tb {lcd_decimal_tb lcd_scene_motion_tb drawers_tb} {
    vsim -L gw5a -t 1ps -onfinish stop -wlf lcd_ui/results/draw_units.wlf $SIM_LIB.$tb +CASES=44
    run -all
    if {[examine -radix unsigned sim:/$tb/test_passed]!=1} {quit -code 1 -force}
    quit -sim
}
echo LCD_DRAW_UNIT_SUITE_PASS
quit -code 0 -force
