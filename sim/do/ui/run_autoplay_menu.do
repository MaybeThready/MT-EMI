onerror {quit -code 1 -force}
set SIM_LIB work_autoplay_menu
do do/common/setup.do
do do/common/setup_gowin.do
file mkdir $SIM_LIB/results
vlog -sv -work $SIM_LIB ../src/common/fsm.v ../src/ui/ui_control_state.v \
    ../src/lcd_ui/lcd_page_program.v ../src/lcd_ui/lcd_text_info.v \
    ../src/lcd_ui/lcd_text_rom.v ../src/lcd_ui/lcd_tile_rom.v \
    tb/ui/autoplay_menu_tb.vt
vsim -L gw5a -t 1ps -onfinish stop -voptargs=+acc \
    -wlf $SIM_LIB/results/autoplay_menu.wlf $SIM_LIB.autoplay_menu_tb
run -all
if {[examine -radix unsigned sim:/autoplay_menu_tb/test_passed] != 1} {quit -code 1 -force}
echo AUTOPLAY_MENU_PASS
quit -code 0 -force
