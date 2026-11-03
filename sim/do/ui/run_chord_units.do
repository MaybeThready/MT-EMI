# Run from formal sim/. Maintained chord regression; no synthesis/PnR.
onerror {quit -code 1 -force}
onbreak {}
set SIM_LIB ../ai_workspace/sim/work_formal_chord_units
do do/common/setup.do
file mkdir $SIM_LIB/results
transcript file $SIM_LIB/results/run.log
transcript on
do do/common/compile_chord.do
vlog -sv -work $SIM_LIB tb/ui/chord_allocator_tb.vt tb/ui/note_frequency_mapper_tb.vt
foreach p {1 2 3 6 32} {
    vsim -t 1ps -onfinish stop -wlf $SIM_LIB/results/allocator_${p}.wlf -gP=$p $SIM_LIB.chord_allocator_tb
    run -all
    if {[examine -radix unsigned sim:/chord_allocator_tb/test_passed] != 1} {quit -code 1 -force}
    quit -sim
}
vsim -t 1ps -onfinish stop -wlf $SIM_LIB/results/frequency.wlf $SIM_LIB.note_frequency_mapper_tb
run -all
if {[examine -radix unsigned sim:/note_frequency_mapper_tb/test_passed] != 1} {quit -code 1 -force}
quit -sim
echo CHORD_UNITS_PASS

if {![info exists CHORD_SUITE]} {quit -code 0 -force}
