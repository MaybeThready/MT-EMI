quietly WaveActivateNextPane {} 0
add wave -group clock sim:/pitch_bend_frequency_mapper_tb/clk_sys
add wave -group clock sim:/pitch_bend_frequency_mapper_tb/rst_n
add wave -group input -radix unsigned sim:/pitch_bend_frequency_mapper_tb/base_freq
add wave -group input -radix hexadecimal sim:/pitch_bend_frequency_mapper_tb/bend_value
add wave -group handshake sim:/pitch_bend_frequency_mapper_tb/in_valid
add wave -group handshake sim:/pitch_bend_frequency_mapper_tb/in_ready
add wave -group handshake sim:/pitch_bend_frequency_mapper_tb/out_valid
add wave -group handshake sim:/pitch_bend_frequency_mapper_tb/out_ready
add wave -group output -radix unsigned sim:/pitch_bend_frequency_mapper_tb/note_freq
add wave -group check -radix unsigned sim:/pitch_bend_frequency_mapper_tb/checked_frames
configure wave -timelineunits us
wave zoomfull
