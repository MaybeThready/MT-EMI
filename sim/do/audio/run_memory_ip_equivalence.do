# Run from formal sim/. Maintained chord regression; no synthesis/PnR.
onerror {quit -code 1 -force}
onbreak {}
set SIM_LIB ../ai_workspace/sim/work_formal_chord_audio_memory
do do/common/setup.do
file mkdir $SIM_LIB/results
transcript file $SIM_LIB/results/run.log
transcript on
do do/common/setup_gowin.do
vlog -sv -work $SIM_LIB ../src/rom_wavetables/rom_wavetables.v ../src/audio_mix_buffer/audio_mix_buffer.v
vlog -sv -work $SIM_LIB tb/audio/memory_functional.vt tb/audio/memory_ip_equivalence_tb.vt
vsim -L gw5a -t 1ps -onfinish stop -wlf $SIM_LIB/results/memory_ip.wlf $SIM_LIB.memory_ip_equivalence_tb
run -all
if {[examine -radix unsigned sim:/memory_ip_equivalence_tb/test_passed] != 1} {quit -code 1 -force}
quit -sim
echo MEMORY_IP_MODELS_PASS

if {![info exists CHORD_SUITE]} {quit -code 0 -force}
