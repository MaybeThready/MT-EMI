# Independent single-note pitch conversion; run with current directory sim/.
vlog -sv -work $SIM_LIB ../src/common/fsm.v
vlog -sv -work $SIM_LIB ../src/drivers/pitch_bend_frequency_mapper.v
