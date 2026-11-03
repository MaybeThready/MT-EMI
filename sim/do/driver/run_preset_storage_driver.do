# Run from sim. All outputs remain in the working copy.
onerror {quit -code 1 -force}
onbreak {resume}
set SIM_LIB work_preset_storage_driver_tb
do do/common/setup.do
file mkdir drivers/results
vlog -sv -work $SIM_LIB ../src/common/fsm.v ../src/signal_detection/signal_sync.v
vlog -sv -work $SIM_LIB ../src/drivers/spi_nor_transfer.v ../src/drivers/spi_nor_flash.v ../src/drivers/preset_storage_driver.v
vlog -sv -work $SIM_LIB tb/drivers/spi_nor_model.vt tb/drivers/preset_storage_driver_tb.vt
vsim -t 1ps -onfinish stop -voptargs=+acc -wlf drivers/results/preset_storage_driver.wlf $SIM_LIB.preset_storage_driver_tb
run -all
if {[examine -radix unsigned sim:/preset_storage_driver_tb/test_passed] != 1} {quit -code 1 -force}
quit -code 0 -force
