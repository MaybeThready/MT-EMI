# Dependencies of the three-chip encoder scanner and its existing UI consumer.
vlog -sv -work $SIM_LIB ../src/common/fsm.v
vlog -sv -work $SIM_LIB ../src/signal_detection/signal_sync.v
vlog -sv -work $SIM_LIB ../src/common/clock_divider.v
vlog -sv -work $SIM_LIB ../src/signal_detection/signal_edge_detector.v
vlog -sv -work $SIM_LIB ../src/system/sys_ticker.v
vlog -sv -work $SIM_LIB ../src/drivers/knob_driver.v
vlog -sv -work $SIM_LIB ../src/ui/knob_event_handler.v
