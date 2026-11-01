quietly WaveActivateNextPane {} 0
add wave -group clocks sim:/test_velocity_tb/clk_sys sim:/test_velocity_tb/rst_n
add wave -group keyboard -radix hexadecimal sim:/test_velocity_tb/physical_keys sim:/test_velocity_tb/dut_u/key_states
add wave -group pressure -radix unsigned sim:/test_velocity_tb/dut_u/key_velocity
add wave -group pressure sim:/test_velocity_tb/mux_addr sim:/test_velocity_tb/mux_en_a_n sim:/test_velocity_tb/mux_en_b_n
add wave -group notes -radix hexadecimal sim:/test_velocity_tb/dut_u/note_on sim:/test_velocity_tb/dut_u/note_off sim:/test_velocity_tb/dut_u/note_busy
add wave -group notes -radix unsigned sim:/test_velocity_tb/dut_u/note_velocity
add wave -group audio -radix decimal sim:/test_velocity_tb/dut_u/audio_monitor
add wave -group audio sim:/test_velocity_tb/dut_u/audio_monitor_valid
add wave -group i2s sim:/test_velocity_tb/i2s_bclk sim:/test_velocity_tb/i2s_lrck sim:/test_velocity_tb/i2s_dout
add wave -group diagnostics sim:/test_velocity_tb/status_led sim:/test_velocity_tb/phase sim:/test_velocity_tb/regression_passed
configure wave -timelineunits ms
wave zoomfull
