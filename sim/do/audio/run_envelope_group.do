set SIM_LIB work_envelope_group
do ../common/setup.do
do ../common/compile_envelope.do
vlog -work $SIM_LIB ../src/adsr_division/adsr_division.vo
vlog -sv -work $SIM_LIB ../src/audio/envelope_group.v
vlog -sv -work $SIM_LIB tb/audio/envelope_group_tb.vt
vsim -t 1ps -voptargs=+acc -L gw5a $SIM_LIB.envelope_group_tb
do wave_envelope_group.do
run -all

