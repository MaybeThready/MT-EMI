# Formal LCD and actual-top integration. No diagnostic projects or copies.
onerror {quit -code 1 -force}
set CHORD_LCD_SUITE 1
do do/lcd_ui/run_chord_lcd_units.do
do do/lcd_ui/run_chord_handoff.do
do do/lcd_ui/run_chord_system.do
do do/lcd_ui/run_chord_pll_smoke.do
echo CHORD_FORMAL_LCD_PASS
quit -code 0 -force
