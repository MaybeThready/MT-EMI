# 从 sim/ 运行。真实RTL + 仿真专用ADCLRC/PLL模型；产物只写入ai_workspace。
onerror {quit -code 1 -force}
onbreak {}
set SIM_LIB ../ai_workspace/sim/work_full_top_peripherals
do do/common/setup.do
set CHORD_REAL_PLL 0
do do/common/compile_chord_system.do
vlog -sv -work $SIM_LIB tb/system/full_top_peripherals_tb.vt
file mkdir $SIM_LIB/results
vsim -L $SIM_LIB -L gw5a -t 1ps -onfinish stop -voptargs=+acc \
    -wlf $SIM_LIB/results/peripherals.wlf $SIM_LIB.full_top_peripherals_tb \
    +RESULTS=$SIM_LIB/results
log sim:/full_top_peripherals_tb/dut/key_states
log sim:/full_top_peripherals_tb/dut/key_velocity
log sim:/full_top_peripherals_tb/dut/bend_value
log sim:/full_top_peripherals_tb/dut/knob_steps_frame
log sim:/full_top_peripherals_tb/dut/knob_pressed_frame
log sim:/full_top_peripherals_tb/dut/note_on
log sim:/full_top_peripherals_tb/dut/note_freq
run -all
if {[examine -radix unsigned sim:/full_top_peripherals_tb/test_passed] != 1} {quit -code 1 -force}
echo FULL_TOP_PERIPHERALS_PASS
quit -code 0 -force
