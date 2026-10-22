do compile_unsigned_fp.do
vlog -sv -work $SIM_LIB ../src/common/fsm.v
do compile_ticker.do
vlog -sv -work $SIM_LIB ../src/audio/phase_accumulator.v

