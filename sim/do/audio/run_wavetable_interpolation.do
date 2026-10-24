set SIM_LIB work_wavetable_interpolation
do ../common/setup.do
do ../common/compile_wavetable_interpolation.do

vlog -sv -work $SIM_LIB tb/audio/wavetable_interpolation_tb.vt

vsim -t 1ps -voptargs=+acc -L gw5a $SIM_LIB.wavetable_interpolation_tb
do wave_wavetable_interpolation.do
run -all
