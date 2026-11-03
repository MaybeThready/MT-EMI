add wave -divider {Input and sample index}
add wave sim:/delay_tb/clk_sys
add wave sim:/delay_tb/rst_n
add wave -radix unsigned sim:/delay_tb/scenario_id
add wave -radix unsigned sim:/delay_tb/sample_index
add wave -radix decimal sim:/delay_tb/audio_in
add wave -radix hex sim:/delay_tb/delay_mix
add wave -radix unsigned sim:/delay_tb/delay_time
add wave -radix hex sim:/delay_tb/delay_feedback

add wave -divider {Completed audio}
add wave -label {Delayed audio} -format Analog-Interpolated -height 100 -radix decimal sim:/delay_tb/observed_audio
add wave -radix decimal sim:/delay_tb/expected_audio
add wave -radix decimal sim:/delay_tb/audio_out

add wave -divider {Valid-ready handshake}
add wave sim:/delay_tb/in_valid
add wave sim:/delay_tb/in_ready
add wave sim:/delay_tb/out_valid
add wave sim:/delay_tb/out_ready

add wave -divider {RAM and scheduler}
add wave sim:/delay_tb/ram_read_en
add wave -radix unsigned sim:/delay_tb/ram_read_addr
add wave -radix decimal sim:/delay_tb/ram_read_data
add wave sim:/delay_tb/ram_write_en
add wave -radix unsigned sim:/delay_tb/ram_write_addr
add wave -radix decimal sim:/delay_tb/ram_write_data
add wave sim:/delay_tb/delay_u/stc
add wave -radix unsigned sim:/delay_tb/delay_u/write_ptr_r
add wave -radix unsigned sim:/delay_tb/delay_u/valid_count_r
