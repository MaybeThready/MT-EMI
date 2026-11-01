# Formal sim/ entry. Same initialized coefficient/SDP models as synthesis RTL.
onerror {quit -code 1 -force}
onbreak {resume}
do do/common/setup_gowin.do
set SIM_LIB work_spectrum_fft
do do/common/setup.do
file mkdir lcd_ui/results
vlog -sv -work $SIM_LIB ../src/common/fsm.v ../src/drivers/lcd_sdp_ram.v
vlog -sv -work $SIM_LIB ../src/lcd_ui/lcd_fft_coeff_rom.v ../src/lcd_ui/lcd_fft1024.v
vlog -sv -work $SIM_LIB tb/lcd_ui/lcd_fft_coeff_rom_tb.vt tb/lcd_ui/lcd_fft1024_tb.vt
foreach tb {lcd_fft_coeff_rom_tb lcd_fft1024_tb} {
    vsim -L gw5a -t 1ps -onfinish stop -wlf lcd_ui/results/${tb}.wlf $SIM_LIB.$tb
    run -all
    if {[examine -radix unsigned sim:/$tb/test_passed]!=1} {quit -code 1 -force}
    quit -sim
}
echo SPECTRUM_FFT_SUITE_PASS
quit -code 0 -force
