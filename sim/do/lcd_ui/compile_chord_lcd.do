# Compile LCD/display RTL and UI from the formal tree, no GPRJ/MPF changes.
vlog -sv -work $SIM_LIB ../src/common/fsm.v
foreach source [glob ../src/fixed_points/*.v ../src/ui/*.v ../src/lcd_ui/*.v] {
    vlog -sv -work $SIM_LIB $source
}
foreach name {lcd_sdp_ram lcd_scene lcd_driver lcd_palette} {
    vlog -sv -work $SIM_LIB ../src/drivers/${name}.v
}
