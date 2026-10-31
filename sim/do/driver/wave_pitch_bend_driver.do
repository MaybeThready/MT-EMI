quietly WaveActivateNextPane {} 0
add wave -group clocks sim:/pitch_bend_driver_tb/clk_sys
add wave -group clocks sim:/pitch_bend_driver_tb/rst_n
add wave -group clocks sim:/pitch_bend_driver_tb/scan_tick_up
add wave -group adc sim:/pitch_bend_driver_tb/dut_u/adc_u/CLK
add wave -group adc sim:/pitch_bend_driver_tb/dut_u/adc_u/ADCREQI
add wave -group adc sim:/pitch_bend_driver_tb/dut_u/adc_u/ADCRDY
add wave -group adc -radix unsigned sim:/pitch_bend_driver_tb/dut_u/adc_u/VSENCTL
add wave -group adc -radix unsigned sim:/pitch_bend_driver_tb/dut_u/adc_u/ADCVALUE
add wave -group adc sim:/pitch_bend_driver_tb/dut_u/busy_seen_r
add wave -group adc -radix unsigned sim:/pitch_bend_driver_tb/dut_u/discarded_r
add wave -group position -radix hexadecimal sim:/pitch_bend_driver_tb/bend_value
add wave -group position sim:/pitch_bend_driver_tb/out_valid
add wave -group position sim:/pitch_bend_driver_tb/out_ready
add wave -group position sim:/pitch_bend_driver_tb/mapper_ready
add wave -group position sim:/pitch_bend_driver_tb/adc_error
add wave -group single_note -radix unsigned sim:/pitch_bend_driver_tb/note_freq
add wave -group single_note sim:/pitch_bend_driver_tb/mapper_valid
add wave -group single_note sim:/pitch_bend_driver_tb/mapper_out_ready
add wave -group checks sim:/pitch_bend_driver_tb/phase
add wave -group checks sim:/pitch_bend_driver_tb/regression_passed
add wave -group checks sim:/pitch_bend_driver_tb/regression_failed
configure wave -timelineunits us
wave zoom full
