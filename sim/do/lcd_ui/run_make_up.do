# From sim/: do do/lcd_ui/run_make_up.do
onerror {quit -code 1 -force}
onbreak {resume}
set SIM_LIB lcd_ui/work_make_up
do do/common/setup.do
vlog -sv -work $SIM_LIB ../src/lcd_ui/lcd_page_program.v tb/lcd_ui/lcd_make_up_tb.vt
vsim -t 1ps -onfinish stop -voptargs=+acc $SIM_LIB.lcd_make_up_tb
run -all
quit -code 0 -force
