onerror {quit -code 1 -force}
onbreak {resume}
set SIM_LIB work_flash_board_test
do do/common/setup.do
file mkdir drivers/results
vlog -sv -work $SIM_LIB ../src/common/fsm.v ../src/signal_detection/signal_sync.v
vlog -sv -work $SIM_LIB ../src/drivers/spi_nor_transfer.v ../src/drivers/spi_nor_flash.v ../src/drivers/preset_storage_driver.v ../src/preset_storage/flash_board_test.v
vlog -sv -work $SIM_LIB tb/drivers/spi_nor_model.vt tb/preset_storage/flash_board_test_tb.vt
vsim -t 1ps -onfinish stop -voptargs=+acc -wlf drivers/results/flash_board_test.wlf $SIM_LIB.flash_board_test_tb
run -all
if {[examine -radix unsigned sim:/flash_board_test_tb/test_passed] != 1} {quit -code 1 -force}
quit -code 0 -force
