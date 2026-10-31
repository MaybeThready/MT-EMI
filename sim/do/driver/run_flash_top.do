# Full active project, controlled analog PLL only; no replacement of digital clocks/reset/UI.
onerror {quit -code 1 -force}
onbreak {resume}
set SIM_LIB work_flash_top_tb
do do/common/setup.do
file mkdir drivers/results
set fd [open ../MT-EMI.gprj r]
set xml [read $fd]
close $fd
foreach line [split $xml \n] {
    if {[regexp {File path="([^"]+\.v)" type="file.verilog" enable="1"} $line -> source]} {
        if {![regexp {src/gowin_pll/gowin_pll_mod.v|src/(adsr_division|rom_wavetables)/|src/ui/ui_audio_probe.v|src/audio/(envelope|wavetable)} $source]} {
            vlog -sv -work $SIM_LIB +incdir+../src ../$source
        }
    }
}
vlog -sv -work $SIM_LIB tb/drivers/flash_pll_model.vt tb/drivers/spi_nor_model.vt tb/top_tb.vt
vsim -t 1ps -onfinish stop -gCONTROLLED_PLL=1 -wlf drivers/results/flash_top.wlf $SIM_LIB.top_tb
run -all
if {[examine -radix unsigned sim:/top_tb/test_passed] != 1} {quit -code 1 -force}
quit -code 0 -force
