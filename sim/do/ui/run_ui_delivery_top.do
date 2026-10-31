# Run from sim/. Requires a configured gw5a simulation library.
onerror {quit -code 1 -force}
onbreak {resume}
set SIM_LIB work_ui_delivery_top
do do/common/setup.do
file mkdir user_interface/results
set fd [open ../MT-EMI.gprj r]
set xml [read $fd]
close $fd
foreach line [split $xml \n] {
    if {[regexp {File path="([^"]+\.v)" type="file.verilog" enable="1"} $line -> source]} {
        if {![regexp {src/gowin_pll/gowin_pll_mod.v|src/adsr_division/} $source]} {
            vlog -sv -work $SIM_LIB +incdir+../src ../$source
        }
    }
}
vlog -sv -work $SIM_LIB tb/audio/adsr_division_functional.vt tb/drivers/flash_pll_model.vt tb/drivers/spi_nor_model.vt tb/ui/top_ui_delivery_tb.vt
vsim -L gw5a -t 1ps -onfinish stop -gCONTROLLED_PLL=1 -wlf user_interface/results/ui_delivery_top.wlf $SIM_LIB.top_ui_delivery_tb
run -all
if {[examine -radix unsigned sim:/top_ui_delivery_tb/test_passed] != 1} {quit -code 1 -force}
quit -code 0 -force
