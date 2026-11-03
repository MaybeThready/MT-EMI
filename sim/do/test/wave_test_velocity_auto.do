quietly WaveActivateNextPane {} 0
add wave sim:/test_velocity_auto_tb/clk_sys sim:/test_velocity_auto_tb/rst_n
add wave -radix unsigned sim:/test_velocity_auto_tb/dut_u/auto_key_r
add wave sim:/test_velocity_auto_tb/mux_addr sim:/test_velocity_auto_tb/mux_en_a_n sim:/test_velocity_auto_tb/mux_en_b_n
add wave -radix unsigned sim:/test_velocity_auto_tb/dut_u/key_velocity sim:/test_velocity_auto_tb/dut_u/note_velocity
add wave -radix decimal sim:/test_velocity_auto_tb/dut_u/audio_monitor
add wave sim:/test_velocity_auto_tb/status_led sim:/test_velocity_auto_tb/regression_passed
configure wave -timelineunits ms
wave zoomfull
