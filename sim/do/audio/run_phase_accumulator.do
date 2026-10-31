set SIM_LIB work_phase_accumulator
do ../common/setup.do
do ../common/compile_phase_accumulator.do
vlog -sv -work $SIM_LIB tb/audio/phase_accumulator_tb.vt
vsim -t 1ps -voptargs=+acc $SIM_LIB.phase_accumulator_tb
do wave_phase_accumulator.do
run -all

