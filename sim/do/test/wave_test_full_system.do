quietly WaveActivateNextPane {} 0
add wave -group inputs sim:/test_full_system_tb/keys sim:/test_full_system_tb/pressure_code sim:/test_full_system_tb/bend_code sim:/test_full_system_tb/ui_button
add wave -group ADC sim:/test_full_system_tb/dut/mux_addr sim:/test_full_system_tb/dut/mux_en_a_n sim:/test_full_system_tb/dut/mux_en_b_n sim:/test_full_system_tb/dut/shared_adc_error
add wave -group UI sim:/test_full_system_tb/dut/key_frame sim:/test_full_system_tb/dut/velocity_frame sim:/test_full_system_tb/dut/bend_frame sim:/test_full_system_tb/dut/knob_steps_frame sim:/test_full_system_tb/dut/menu_page
add wave -group audio sim:/test_full_system_tb/dut/note_on sim:/test_full_system_tb/dut/note_off sim:/test_full_system_tb/dut/note_freq sim:/test_full_system_tb/dut/note_velocity sim:/test_full_system_tb/dut/mixer_audio
add wave -group I2S sim:/test_full_system_tb/i2s_bclk sim:/test_full_system_tb/i2s_lrck sim:/test_full_system_tb/i2s_dout sim:/test_full_system_tb/dut/played_pcm
add wave -group LCD sim:/test_full_system_tb/dut/ui_display_state sim:/test_full_system_tb/dut/lcd_display_u/wave_valid sim:/test_full_system_tb/dut/lcd_display_u/spectrum_valid sim:/test_full_system_tb/lcd_en
add wave -group status sim:/test_full_system_tb/status_led sim:/test_full_system_tb/test_passed
configure wave -timelineunits ms
wave zoom full
