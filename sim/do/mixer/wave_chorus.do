add wave -divider {Input and sample index}
add wave sim:/chorus_tb/clk_sys
add wave sim:/chorus_tb/rst_n
add wave -radix unsigned sim:/chorus_tb/scenario_id
add wave -radix unsigned sim:/chorus_tb/sample_index
add wave -radix decimal sim:/chorus_tb/audio_in
add wave -radix hex sim:/chorus_tb/chorus_mix
add wave -radix hex sim:/chorus_tb/chorus_rate
add wave -radix unsigned sim:/chorus_tb/chorus_depth

add wave -divider {Completed audio}
add wave -label {Chorus audio} -format Analog-Interpolated -height 100 -radix decimal sim:/chorus_tb/observed_audio
add wave -radix decimal sim:/chorus_tb/expected_audio
add wave -radix decimal sim:/chorus_tb/chorus_u/wet_r
add wave -radix decimal sim:/chorus_tb/audio_out

add wave -divider {Valid-ready handshake}
add wave sim:/chorus_tb/in_valid
add wave sim:/chorus_tb/in_ready
add wave sim:/chorus_tb/out_valid
add wave sim:/chorus_tb/out_ready

add wave -divider {LFO and RAM}
add wave -radix hex sim:/chorus_tb/chorus_u/phase_r
add wave -radix unsigned sim:/chorus_tb/chorus_u/delay_samples
add wave -radix unsigned sim:/chorus_tb/chorus_u/fraction_r
add wave sim:/chorus_tb/ram_read_en
add wave -radix unsigned sim:/chorus_tb/ram_read_addr
add wave -radix decimal sim:/chorus_tb/ram_read_data
add wave sim:/chorus_tb/ram_write_en
add wave -radix unsigned sim:/chorus_tb/ram_write_addr
add wave -radix decimal sim:/chorus_tb/ram_write_data
add wave sim:/chorus_tb/chorus_u/stc
