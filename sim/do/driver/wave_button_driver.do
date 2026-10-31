add wave -divider {Clock and physical pins}
add wave sim:/button_driver_tb/clk_sys
add wave sim:/button_driver_tb/rst_n
add wave sim:/button_driver_tb/scan_tick_up
add wave -radix binary sim:/button_driver_tb/button_pins
add wave -radix binary sim:/button_driver_tb/button_driver_u/button_sync

add wave -divider {Debounce}
add wave -radix binary sim:/button_driver_tb/button_driver_u/candidate_valid_r
add wave -radix binary sim:/button_driver_tb/button_driver_u/filtered_state_r
add wave -radix unsigned sim:/button_driver_tb/button_driver_u/stable_count_r(0)
add wave -radix unsigned sim:/button_driver_tb/button_driver_u/stable_count_r(1)

add wave -divider {Valid ready transfer}
add wave -radix binary sim:/button_driver_tb/button_states
add wave sim:/button_driver_tb/out_valid
add wave sim:/button_driver_tb/out_ready
add wave sim:/button_driver_tb/button_driver_u/frame_pending_r
add wave -radix unsigned sim:/button_driver_tb/transfer_count
