quietly WaveActivateNextPane {} 0
add wave sim:/test_velocity_routing_tb/clk_sys sim:/test_velocity_routing_tb/rst_n
add wave -radix unsigned sim:/test_velocity_routing_tb/key
add wave -radix hexadecimal sim:/test_velocity_routing_tb/key_states
add wave -radix unsigned sim:/test_velocity_routing_tb/key_velocity sim:/test_velocity_routing_tb/note_velocity
add wave sim:/test_velocity_routing_tb/in_valid sim:/test_velocity_routing_tb/in_ready
add wave sim:/test_velocity_routing_tb/note_on sim:/test_velocity_routing_tb/out_valid
add wave sim:/test_velocity_routing_tb/regression_passed
configure wave -timelineunits us
wave zoomfull
