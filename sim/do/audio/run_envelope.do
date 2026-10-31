set SIM_LIB work_envelope
do ../common/setup.do
do ../common/compile_envelope.do
vlog -sv -work $SIM_LIB tb/audio/envelope_tb.vt
vsim -t 1ps -voptargs=+acc $SIM_LIB.envelope_tb
do wave_envelope.do
run -all

