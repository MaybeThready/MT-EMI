quietly WaveActivateNextPane {} 0
add wave -group clocks sim:/test_pitch_bend_tb/clk_sys sim:/test_pitch_bend_tb/rst_n
add wave -group keyboard sim:/test_pitch_bend_tb/physical_keys
add wave -group pressure sim:/test_pitch_bend_tb/pressure_code sim:/test_pitch_bend_tb/dut_u/test_velocity_core_u/key_velocity
add wave -group adc sim:/test_pitch_bend_tb/dut_u/shared_adc_manager_u/state_r
add wave -group adc sim:/test_pitch_bend_tb/dut_u/shared_adc_manager_u/owner_bend_r
add wave -group adc sim:/test_pitch_bend_tb/pressure_requests sim:/test_pitch_bend_tb/bend_requests
add wave -group bend sim:/test_pitch_bend_tb/bend_code sim:/test_pitch_bend_tb/dut_u/bend_value
add wave -group bend sim:/test_pitch_bend_tb/dut_u/bend_valid
add wave -group notes sim:/test_pitch_bend_tb/dut_u/test_velocity_core_u/note_freq
add wave -group audio sim:/test_pitch_bend_tb/dut_u/test_velocity_core_u/audio_monitor
add wave -group audio sim:/test_pitch_bend_tb/dut_u/test_velocity_core_u/audio_monitor_valid
add wave -group i2s sim:/test_pitch_bend_tb/i2s_bclk sim:/test_pitch_bend_tb/i2s_lrck sim:/test_pitch_bend_tb/i2s_dout
add wave -group diagnostics sim:/test_pitch_bend_tb/status_led sim:/test_pitch_bend_tb/regression_passed
wave zoomfull
