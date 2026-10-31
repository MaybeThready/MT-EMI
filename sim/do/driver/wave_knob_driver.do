quietly WaveActivateNextPane {} 0
add wave -group clocks sim:/knob_driver_tb/clk_sys
add wave -group clocks sim:/knob_driver_tb/rst_n
add wave -group clocks sim:/knob_driver_tb/scan_tick_up
add wave -group serial sim:/knob_driver_tb/load_n
add wave -group serial sim:/knob_driver_tb/shift_clk
add wave -group serial sim:/knob_driver_tb/serial_data
add wave -group input -radix hexadecimal sim:/knob_driver_tb/physical_a
add wave -group input -radix hexadecimal sim:/knob_driver_tb/physical_b
add wave -group input -radix hexadecimal sim:/knob_driver_tb/physical_pressed
add wave -group output -radix hexadecimal sim:/knob_driver_tb/knob_states
add wave -group output -radix hexadecimal sim:/knob_driver_tb/knob_dirs
add wave -group output -radix hexadecimal sim:/knob_driver_tb/knob_pressed
add wave -group output sim:/knob_driver_tb/out_valid
add wave -group output sim:/knob_driver_tb/out_ready
add wave -group output sim:/knob_driver_tb/overflow
add wave -group output sim:/knob_driver_tb/scan_error
add wave -group ui sim:/knob_driver_tb/ui_delta
add wave -group ui sim:/knob_driver_tb/ui_pressed_event
add wave -group result -radix unsigned sim:/knob_driver_tb/main_phase
add wave -group result -radix unsigned sim:/knob_driver_tb/checked_events
add wave -group result sim:/knob_driver_tb/regression_passed
configure wave -timelineunits us
update
wave zoom full
