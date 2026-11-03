# 整机相关驱动专项回归；从sim/运行，绕开旧DO中的工作目录假设。
# 仅复用原测试平台；不修改驱动、原TB或根工程的配置。
onerror {quit -code 1 -force}
onbreak {}
set MT_RUN_NAME test_full_system_drivers
do do/common/output_paths.do
set SIM_LIB [file join $MT_AI sim test_full_system drivers]
file mkdir [file dirname $SIM_LIB]
if {![file isdirectory $SIM_LIB]} {vlib $SIM_LIB}
do do/common/compile_test_full_system.do
vlog -sv -work $SIM_LIB ../src/drivers/pitch_bend_frequency_mapper.v
foreach test {keyboard_driver_tb keyboard_adc_tb keyboard_pressure_scanner_tb button_driver_tb knob_driver_tb i2s_driver_tb pitch_bend_driver_tb} {
    if {$test eq "i2s_driver_tb"} {
        # 旧TB成功时只有PASS文本；给临时副本增加成功标记，避免把$fatal停止误认为通过。
        set fd [open tb/drivers/i2s_driver_tb.vt r]
        set source [read $fd]
        close $fd
        if {[string first {module i2s_driver_tb();} $source]<0 || [string first {$display("PASS i2s_driver:} $source]<0} {error "I2S reference TB success marker changed"}
        set source [string map [list {module i2s_driver_tb();} {module i2s_driver_tb(); reg regression_passed=1'b0;} {$display("PASS i2s_driver:} {regression_passed=1'b1; $display("PASS i2s_driver:}] $source]
        set fd [open [file join $MT_AI sim test_full_system i2s_driver_reference.vt] w]
        puts $fd $source
        close $fd
        vlog -sv -work $SIM_LIB [file join $MT_AI sim test_full_system i2s_driver_reference.vt]
    } else {
        vlog -sv -work $SIM_LIB tb/drivers/${test}.vt
    }
    vsim -L $SIM_LIB -L gw5a -t 1ps -onfinish stop \
        -wlf [file join $MT_AI sim test_full_system ${test}.wlf] $SIM_LIB.$test
    run -all
    set flag [expr {$test eq "button_driver_tb" ? "test_passed" : "regression_passed"}]
    if {[examine -radix unsigned sim:/$test/$flag] != 1} {quit -code 1 -force}
    quit -sim
}
echo TEST_FULL_SYSTEM_DRIVERS_PASS
quit -code 0 -force
