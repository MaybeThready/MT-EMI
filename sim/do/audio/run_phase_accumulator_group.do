set SIM_LIB work_phase_accumulator_group
do ../common/setup.do
do ../common/compile_phase_accumulator.do
vlog -sv -work $SIM_LIB ../src/audio/phase_accumulator_group.v
vlog -sv -work $SIM_LIB tb/audio/phase_accumulator_group_tb.vt
vsim -t 1ps -voptargs=+acc $SIM_LIB.phase_accumulator_group_tb
do wave_phase_accumulator_group.do
run -all

