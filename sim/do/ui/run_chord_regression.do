# Run from formal sim/. Maintained chord regression; no synthesis/PnR.
onerror {quit -code 1 -force}
onbreak {}
set SIM_LIB ../ai_workspace/sim/work_formal_chord_regression
do do/common/setup.do
file mkdir $SIM_LIB/results
transcript file $SIM_LIB/results/run.log
transcript on
do do/common/compile_chord.do
set tests {chord_context_tb user_interface_s2_tb ui_input_frame_joiner_tb note_pitch_bend_tb ui_display_snapshot_tb}
foreach tb $tests {vlog -sv -work $SIM_LIB tb/ui/${tb}.vt}
foreach tb $tests {
    vsim -t 1ps -onfinish stop -wlf $SIM_LIB/results/${tb}.wlf +ASSETS=../assets/ui/test_vectors/control +RESULTS=$SIM_LIB/results $SIM_LIB.$tb
    run -all
    if {[examine -radix unsigned sim:/$tb/test_passed]!=1} {quit -code 1 -force}
    quit -sim
}
echo CHORD_REGRESSION_PASS

if {![info exists CHORD_SUITE]} {quit -code 0 -force}
