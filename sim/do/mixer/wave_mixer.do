add wave -divider {Sample input and PCM output}
add wave sim:/mixer_tb/clk_sys
add wave sim:/mixer_tb/rst_n
add wave -radix unsigned sim:/mixer_tb/sample_index
add wave -radix decimal sim:/mixer_tb/audio_in
add wave -radix hex sim:/mixer_tb/balance_volume
add wave -radix hex sim:/mixer_tb/master_volume
add wave -label {PCM waveform} -format Analog-Interpolated -height 100 -radix decimal sim:/mixer_tb/observed_audio
add wave -radix decimal sim:/mixer_tb/expected_audio
add wave -radix decimal sim:/mixer_tb/audio_out

add wave -divider {Valid-ready and chain state}
add wave sim:/mixer_tb/in_valid
add wave sim:/mixer_tb/in_ready
add wave sim:/mixer_tb/out_valid
add wave sim:/mixer_tb/out_ready
add wave -radix unsigned sim:/mixer_tb/mixer_u/stc
add wave -radix decimal sim:/mixer_tb/mixer_u/sample_r
add wave -radix decimal sim:/mixer_tb/mixer_u/dist_audio
add wave -radix decimal sim:/mixer_tb/mixer_u/chorus_audio
add wave -radix decimal sim:/mixer_tb/mixer_u/delay_audio
add wave -radix decimal sim:/mixer_tb/mixer_u/reverb_audio

add wave -divider {Shared RAM}
add wave sim:/mixer_tb/mixer_u/ram_read_en
add wave -radix unsigned sim:/mixer_tb/mixer_u/ram_read_addr
add wave -radix decimal sim:/mixer_tb/mixer_u/ram_read_data
add wave sim:/mixer_tb/mixer_u/ram_write_en
add wave -radix unsigned sim:/mixer_tb/mixer_u/ram_write_addr
add wave -radix decimal sim:/mixer_tb/mixer_u/ram_write_data
