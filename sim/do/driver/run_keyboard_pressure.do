# Run from sim/: do do/driver/run_keyboard_pressure.do
# Functional ADC/mux model only; analog accuracy and real filter settling require hardware.
onerror {abort all}
set SIM_LIB work_keyboard_pressure
do ../common/setup.do
do ../common/compile_keyboard_driver.do
vlog -sv -work $SIM_LIB tb/models/adclrc_model.vt
vlog -sv -work $SIM_LIB tb/drivers/keyboard_pressure_scanner_tb.vt
vsim -t 1ps -voptargs=+acc -onfinish stop -wlf $SIM_LIB/keyboard_pressure_scanner_tb.wlf $SIM_LIB.keyboard_pressure_scanner_tb
do wave_keyboard_pressure.do
run -all
