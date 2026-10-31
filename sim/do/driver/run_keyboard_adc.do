# Run from sim/: do do/driver/run_keyboard_adc.do
onerror {abort all}
set SIM_LIB work_keyboard_adc
do ../common/setup.do
do ../common/compile_keyboard_driver.do
vlog -sv -work $SIM_LIB tb/models/adclrc_model.vt
vlog -sv -work $SIM_LIB tb/drivers/keyboard_adc_tb.vt
vsim -t 1ps -voptargs=+acc -onfinish stop -wlf $SIM_LIB/keyboard_adc_tb.wlf $SIM_LIB.keyboard_adc_tb
add wave sim:/keyboard_adc_tb/*
add wave sim:/keyboard_adc_tb/keyboard_adc_u/*
run -all
