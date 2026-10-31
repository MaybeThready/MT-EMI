do do/common/compile_ticker.do
vlog -sv -work $SIM_LIB ../src/common/fsm.v
vlog -sv -work $SIM_LIB ../src/drivers/i2s_driver.v
