add wave -divider {Input and sample index}
add wave sim:/reverb_tb/clk_sys
add wave sim:/reverb_tb/rst_n
add wave -radix unsigned sim:/reverb_tb/scenario_id
add wave -radix unsigned sim:/reverb_tb/sample_index
add wave -radix decimal sim:/reverb_tb/audio_in
add wave -radix hex sim:/reverb_tb/reverb_mix
add wave -radix hex sim:/reverb_tb/reverb_feedback
add wave -radix hex sim:/reverb_tb/reverb_damping

add wave -divider {Completed audio}
add wave -label {Impulse response} -format Analog-Interpolated -height 100 -radix decimal sim:/reverb_tb/observed_audio
add wave -radix decimal sim:/reverb_tb/audio_out
add wave -radix unsigned sim:/reverb_tb/wet_count

add wave -divider {Valid-ready handshake}
add wave sim:/reverb_tb/in_valid
add wave sim:/reverb_tb/in_ready
add wave sim:/reverb_tb/out_valid
add wave sim:/reverb_tb/out_ready

add wave -divider {RAM and scheduler}
add wave sim:/reverb_tb/ram_read_en
add wave -radix unsigned sim:/reverb_tb/ram_read_addr
add wave -radix decimal sim:/reverb_tb/ram_read_data
add wave sim:/reverb_tb/ram_write_en
add wave -radix unsigned sim:/reverb_tb/ram_write_addr
add wave -radix decimal sim:/reverb_tb/ram_write_data
add wave sim:/reverb_tb/reverb_u/stc
add wave -radix unsigned sim:/reverb_tb/reverb_u/stage_index
