# Dedicated ADC behavior is supplied by the testbench, not the vendor's empty ADCLRC stub.
vlog -sv -work $SIM_LIB ../src/common/fsm.v
vlog -sv -work $SIM_LIB ../src/signal_detection/signal_sync.v
vlog -sv -work $SIM_LIB ../src/drivers/pitch_bend_driver.v
vlog -sv -work $SIM_LIB ../src/drivers/pitch_bend_frequency_mapper.v
