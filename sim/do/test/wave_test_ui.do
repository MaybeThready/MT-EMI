quietly WaveActivateNextPane {} 0
add wave -group input sim:/test_ui_tb/ui_button sim:/test_ui_tb/keys
add wave -group serial sim:/test_ui_tb/load_n sim:/test_ui_tb/key_clk sim:/test_ui_tb/knob_load_n sim:/test_ui_tb/knob_shift_clk sim:/test_ui_tb/knob_serial_data
add wave -group handshake sim:/test_ui_tb/dut/keyboard_valid sim:/test_ui_tb/dut/knob_valid sim:/test_ui_tb/dut/button_valid sim:/test_ui_tb/dut/combined_valid sim:/test_ui_tb/dut/ui_in_ready sim:/test_ui_tb/dut/ui_out_valid
add wave -group ui sim:/test_ui_tb/dut/menu_page sim:/test_ui_tb/dut/button_frame_r sim:/test_ui_tb/dut/knob_steps_r sim:/test_ui_tb/dut/wavetable_interp sim:/test_ui_tb/dut/ui_display_valid
add wave -group audio sim:/test_ui_tb/dut/mixer_audio sim:/test_ui_tb/dut/mixer_out_valid sim:/test_ui_tb/dut/i2s_ready
add wave -group result sim:/test_ui_tb/status_led sim:/test_ui_tb/regression_passed
