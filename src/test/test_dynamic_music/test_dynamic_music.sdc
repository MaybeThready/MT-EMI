# 50 MHz oscillator. Gowin derives the existing PLL output clock automatically.
create_clock -name clk_core -period 20.000 -waveform {0.000 10.000} [get_ports {clk_core}]
# Exempt only asynchronous reset requests entering the two-stage reset synchronizer.
set_false_path -to [get_pins {sys_clocker_u/rst_sync_u/signal_buff1_0_s0/CLEAR}]
set_false_path -to [get_pins {sys_clocker_u/rst_sync_u/signal_buff2_0_s0/CLEAR}]
