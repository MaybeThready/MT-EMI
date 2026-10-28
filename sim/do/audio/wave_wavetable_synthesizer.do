add wave -divider {Sample clock and handshakes}
add wave sim:/wavetable_synthesizer_tb/clk_sys
add wave sim:/wavetable_synthesizer_tb/rst_n
add wave sim:/wavetable_synthesizer_tb/smp_tick_up
add wave -radix unsigned sim:/wavetable_synthesizer_tb/scenario_id
add wave -radix unsigned sim:/wavetable_synthesizer_tb/sample_index
add wave sim:/wavetable_synthesizer_tb/in_valid
add wave sim:/wavetable_synthesizer_tb/in_ready
add wave sim:/wavetable_synthesizer_tb/out_valid
add wave sim:/wavetable_synthesizer_tb/out_ready

add wave -divider {Completed audio samples}
add wave -label {Observed audio} -format Analog-Interpolated -height 100 -radix decimal sim:/wavetable_synthesizer_tb/observed_audio
add wave -label {Expected audio} -format Analog-Interpolated -height 100 -radix decimal sim:/wavetable_synthesizer_tb/expected_audio

add wave -divider {Voice-by-voice accumulation}
add wave -label {Raw audio_out} -radix decimal sim:/wavetable_synthesizer_tb/audio_out
add wave -radix unsigned sim:/wavetable_synthesizer_tb/ws_u/lane_index
add wave sim:/wavetable_synthesizer_tb/ws_u/stc
add wave sim:/wavetable_synthesizer_tb/ws_u/sub_in_ready
add wave sim:/wavetable_synthesizer_tb/ws_u/sub_out_valid
add wave -radix decimal sim:/wavetable_synthesizer_tb/ws_u/sample_point
add wave -radix hex sim:/wavetable_synthesizer_tb/ws_u/volume_lane_r
add wave -radix decimal sim:/wavetable_synthesizer_tb/ws_u/voice_sample
add wave -radix decimal sim:/wavetable_synthesizer_tb/ws_u/audio_sum_r
