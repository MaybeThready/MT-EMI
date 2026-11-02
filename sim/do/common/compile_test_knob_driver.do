# Reuse the original driver/UI consumer compile list; no vendor IP is needed by the core TB.
do do/common/compile_knob_driver.do
vlog -sv -work $SIM_LIB ../src/system/sys_clocker.v
vlog -sv -work $SIM_LIB ../src/test/test_knob_driver/test_knob_driver.v
