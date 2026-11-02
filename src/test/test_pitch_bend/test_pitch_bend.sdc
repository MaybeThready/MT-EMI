# Existing PLL is modeled automatically by Gowin: input 50 MHz, ratio 112/57.
create_clock -name clk_core -period 20.000 -waveform {0.000 10.000} [get_ports {clk_core}]
# ADC is another /64. Target the stable hard-IP CLK pin after equivalent-register sharing.
create_generated_clock -name clk_shared_adc -source [get_ports {clk_core}] -multiply_by 7 -divide_by 228 [get_pins {test_pitch_bend_core_u/shared_adc_manager_u/keyboard_adc_u/adc_u/CLK}]
# Only the asynchronous request entering the reset synchronizer is exempt.
set_false_path -to [get_pins {sys_clocker_u/rst_sync_u/signal_buff1_0_s0/CLEAR}]
set_false_path -to [get_pins {sys_clocker_u/rst_sync_u/signal_buff2_0_s0/CLEAR}]
