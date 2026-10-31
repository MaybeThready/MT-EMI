add wave -divider {Input and sample index}
add wave sim:/distortion_tb/clk_sys
add wave sim:/distortion_tb/rst_n
add wave -radix unsigned sim:/distortion_tb/scenario_id
add wave -radix unsigned sim:/distortion_tb/sample_index
add wave -radix decimal sim:/distortion_tb/audio_in
add wave -radix hex sim:/distortion_tb/distortion_mix
add wave -radix hex sim:/distortion_tb/distortion_gain
add wave -radix hex sim:/distortion_tb/distortion_tone

add wave -divider {Completed audio}
add wave -label {Distorted audio} -format Analog-Interpolated -height 100 -radix decimal sim:/distortion_tb/observed_audio
add wave -radix decimal sim:/distortion_tb/expected_audio
add wave -radix decimal sim:/distortion_tb/audio_out
add wave -radix decimal sim:/distortion_tb/distortion_u/clipped_r
add wave -radix decimal sim:/distortion_tb/distortion_u/tone_state_r

add wave -divider {Valid-ready handshake}
add wave sim:/distortion_tb/in_valid
add wave sim:/distortion_tb/in_ready
add wave sim:/distortion_tb/out_valid
add wave sim:/distortion_tb/out_ready
add wave sim:/distortion_tb/distortion_u/stc
