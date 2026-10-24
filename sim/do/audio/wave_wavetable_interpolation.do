add wave -divider {Test and handshakes}
add wave sim:/wavetable_interpolation_tb/clk_sys
add wave sim:/wavetable_interpolation_tb/rst_n
add wave sim:/wavetable_interpolation_tb/scenario_id
add wave sim:/wavetable_interpolation_tb/in_valid
add wave sim:/wavetable_interpolation_tb/in_ready
add wave sim:/wavetable_interpolation_tb/out_valid
add wave sim:/wavetable_interpolation_tb/out_ready

add wave -divider {Waveform and reference}
add wave -radix unsigned sim:/wavetable_interpolation_tb/observed_phase
add wave -radix unsigned sim:/wavetable_interpolation_tb/observed_wave_0
add wave -radix unsigned sim:/wavetable_interpolation_tb/observed_wave_1
add wave -radix hex sim:/wavetable_interpolation_tb/observed_coeff
add wave -format Analog-Step -radix decimal sim:/wavetable_interpolation_tb/expected_point
add wave -format Analog-Step -radix decimal sim:/wavetable_interpolation_tb/sample_point

add wave -divider {ROM and interpolation internals}
add wave -radix hex sim:/wavetable_interpolation_tb/wi_u/rom_addr
add wave -radix decimal sim:/wavetable_interpolation_tb/wi_u/rom_data
add wave -radix decimal sim:/wavetable_interpolation_tb/wi_u/sample_0_r
add wave -radix decimal sim:/wavetable_interpolation_tb/wi_u/sample_1_r
add wave -radix decimal sim:/wavetable_interpolation_tb/wi_u/sample_diff_r
add wave -radix decimal sim:/wavetable_interpolation_tb/wi_u/mult_result
add wave sim:/wavetable_interpolation_tb/wi_u/stc
