# From sim/: do do/lcd_ui/run_detune_page.do
onerror {quit -code 1 -force}
onbreak {resume}
set SIM_LIB work_lcd_detune_page
do do/common/setup.do
vlog -sv -work $SIM_LIB ../src/lcd_ui/lcd_page_program.v tb/lcd_ui/lcd_detune_page_tb.vt
vsim -t 1ps -voptargs=+acc $SIM_LIB.lcd_detune_page_tb
run -all
quit -code 0 -force
