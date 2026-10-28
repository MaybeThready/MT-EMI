add wave -divider {Sampling and handshakes}
add wave sim:/channel_rack_tb/clk_sys
add wave sim:/channel_rack_tb/rst_n
add wave sim:/channel_rack_tb/smp_tick_up
add wave -radix unsigned sim:/channel_rack_tb/scenario_id
add wave -radix unsigned sim:/channel_rack_tb/sample_index
add wave sim:/channel_rack_tb/note_on
add wave sim:/channel_rack_tb/note_off
add wave sim:/channel_rack_tb/note_busy
add wave sim:/channel_rack_tb/in_valid
add wave sim:/channel_rack_tb/in_ready
add wave sim:/channel_rack_tb/out_valid
add wave sim:/channel_rack_tb/out_ready

add wave -divider {Completed audio samples}
add wave -label {Observed audio} -format Analog-Interpolated -height 100 -radix decimal sim:/channel_rack_tb/observed_audio
add wave -label {Expected audio} -format Analog-Interpolated -height 100 -radix decimal sim:/channel_rack_tb/expected_audio
add wave -label {Raw audio_out} -radix decimal sim:/channel_rack_tb/audio_out

add wave -divider {Voice states}
add wave -radix unsigned sim:/channel_rack_tb/observed_phase_0
add wave -radix unsigned sim:/channel_rack_tb/observed_phase_1
add wave -radix hex sim:/channel_rack_tb/observed_envelope_0
add wave -radix hex sim:/channel_rack_tb/observed_envelope_1
add wave -radix hex sim:/channel_rack_tb/observed_volume_0
add wave -radix hex sim:/channel_rack_tb/observed_volume_1

add wave -divider {Rack scheduling}
add wave sim:/channel_rack_tb/rack_u/stc
add wave -radix unsigned sim:/channel_rack_tb/rack_u/lane_index
add wave sim:/channel_rack_tb/rack_u/phase_out_valid
add wave sim:/channel_rack_tb/rack_u/envelope_out_valid
add wave sim:/channel_rack_tb/rack_u/synth_in_valid
add wave sim:/channel_rack_tb/rack_u/synth_in_ready
add wave sim:/channel_rack_tb/rack_u/synth_out_valid
