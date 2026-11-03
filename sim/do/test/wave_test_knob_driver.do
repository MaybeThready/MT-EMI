quietly WaveActivateNextPane {} 0
add wave -group clocks sim:/test_knob_driver_tb/clk_sys sim:/test_knob_driver_tb/rst_n
add wave -group pcb -radix hexadecimal sim:/test_knob_driver_tb/physical_a sim:/test_knob_driver_tb/physical_b sim:/test_knob_driver_tb/physical_pressed
add wave -group serial sim:/test_knob_driver_tb/load_n sim:/test_knob_driver_tb/shift_clk sim:/test_knob_driver_tb/serial_data
add wave -group driver sim:/test_knob_driver_tb/dut_u/driver_valid sim:/test_knob_driver_tb/dut_u/driver_ready
add wave -group driver -radix hexadecimal sim:/test_knob_driver_tb/dut_u/knob_states sim:/test_knob_driver_tb/dut_u/knob_dirs sim:/test_knob_driver_tb/dut_u/knob_pressed
add wave -group ui -radix decimal sim:/test_knob_driver_tb/dut_u/knob_delta
add wave -group ui sim:/test_knob_driver_tb/dut_u/event_valid sim:/test_knob_driver_tb/monitor_ready sim:/test_knob_driver_tb/dut_u/knob_pressed_event
add wave -group leds sim:/test_knob_driver_tb/status_led sim:/test_knob_driver_tb/dut_u/fault_r
add wave -group result sim:/test_knob_driver_tb/phase sim:/test_knob_driver_tb/regression_passed
configure wave -timelineunits ms
wave zoomfull
