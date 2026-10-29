onerror {quit -code 1 -force}
onbreak {resume}
set SIM_LIB work_flash_units
do do/common/setup.do
file mkdir drivers/results
vlog -sv -work $SIM_LIB ../src/common/fsm.v ../src/signal_detection/signal_sync.v
vlog -sv -work $SIM_LIB ../src/drivers/spi_nor_transfer.v ../src/drivers/spi_nor_flash.v ../src/drivers/preset_storage_driver.v
vlog -sv -work $SIM_LIB ../src/ui/preset_record_codec.v ../src/ui/ui_preset_controller.v
vlog -sv -work $SIM_LIB tb/drivers/spi_nor_model.vt tb/drivers/spi_nor_transfer_tb.vt tb/drivers/spi_nor_flash_tb.vt tb/ui/ui_flash_integration_tb.vt
foreach tb {spi_nor_transfer_tb spi_nor_flash_tb ui_flash_integration_tb} {
    vsim -t 1ps -onfinish stop -voptargs=+acc -wlf drivers/results/${tb}.wlf $SIM_LIB.$tb
    run -all
    if {[examine -radix unsigned sim:/$tb/test_passed] != 1} {quit -code 1 -force}
    quit -sim
}
quit -code 0 -force
