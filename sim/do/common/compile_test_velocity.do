# Run from sim/. Prefer a mapped gw5a library; otherwise set the local GOWIN_HOME environment variable.
set GOWIN_SIM_LIB gw5a
if {[catch {vmap $GOWIN_SIM_LIB}]} {
    set primitive_file {}
    if {[info exists env(GOWIN_HOME)]} {
        foreach relative_path {simlib/gw5a/prim_sim.v IDE/simlib/gw5a/prim_sim.v} {
            set candidate [file join $env(GOWIN_HOME) $relative_path]
            if {[file isfile $candidate]} {set primitive_file $candidate; break}
        }
    }
    if {$primitive_file eq {}} {
        error {Map the Gowin gw5a simulation library, or set GOWIN_HOME to its IDE/install directory.}
    }
    set GOWIN_SIM_LIB ${SIM_LIB}_gw5a
    if {[file isdirectory $GOWIN_SIM_LIB]} {vdel -lib $GOWIN_SIM_LIB -all}
    vlib $GOWIN_SIM_LIB
    vlog -work $GOWIN_SIM_LIB $primitive_file
}
# Default: cycle-checked IP behavior model. Optional gate-level vendor netlist is much slower in Starter.
if {[info exists TEST_VELOCITY_VENDOR_DIVIDER] && $TEST_VELOCITY_VENDOR_DIVIDER} {
    vlog -work $SIM_LIB ../src/adsr_division/adsr_division.vo
} else {
    vlog -sv -work $SIM_LIB tb/models/adsr_division_model.vt
}
vlog -sv +incdir+../src/audio -work $SIM_LIB ../src/audio/channel_rack.v
vlog -sv +incdir+../src/audio -work $SIM_LIB ../src/audio/envelope.v
vlog -sv +incdir+../src/audio -work $SIM_LIB ../src/audio/envelope_group.v
vlog -sv +incdir+../src/audio -work $SIM_LIB ../src/audio/phase_accumulator.v
vlog -sv +incdir+../src/audio -work $SIM_LIB ../src/audio/phase_accumulator_group.v
vlog -sv +incdir+../src/audio -work $SIM_LIB ../src/audio/detuned_phase_group.v
vlog -sv +incdir+../src/audio -work $SIM_LIB ../src/audio/wavetable_interpolation.v
vlog -sv +incdir+../src/audio -work $SIM_LIB ../src/audio/wavetable_synthesizer.v
vlog -sv +incdir+../src/audio -work $SIM_LIB ../src/common/clock_divider.v
vlog -sv +incdir+../src/audio -work $SIM_LIB ../src/common/fsm.v
vlog -sv +incdir+../src/audio -work $SIM_LIB ../src/drivers/i2s_driver.v
vlog -sv +incdir+../src/audio -work $SIM_LIB ../src/drivers/keyboard_adc.v
vlog -sv +incdir+../src/audio -work $SIM_LIB ../src/drivers/keyboard_pressure_scanner.v
vlog -sv +incdir+../src/audio -work $SIM_LIB ../src/drivers/keyboard_driver.v
vlog -sv +incdir+../src/audio -work $SIM_LIB ../src/fixed_points/signed_fp_norm.v
vlog -sv +incdir+../src/audio -work $SIM_LIB ../src/fixed_points/signed_fp_op.v
vlog -sv +incdir+../src/audio -work $SIM_LIB ../src/fixed_points/unsigned_fp_norm.v
vlog -sv +incdir+../src/audio -work $SIM_LIB ../src/fixed_points/unsigned_fp_op.v
vlog -sv +incdir+../src/audio -work $SIM_LIB ../src/gowin_pll/gowin_pll.v
vlog -sv +incdir+../src/audio -work $SIM_LIB ../src/gowin_pll/gowin_pll_mod.v
vlog -sv +incdir+../src/audio -work $SIM_LIB ../src/pll_init.v
vlog -sv +incdir+../src/audio -work $SIM_LIB ../src/rom_wavetables/rom_wavetables.v
vlog -sv +incdir+../src/audio -work $SIM_LIB ../src/signal_detection/signal_sync.v
vlog -sv +incdir+../src/audio -work $SIM_LIB ../src/signal_detection/signal_edge_detector.v
vlog -sv +incdir+../src/audio -work $SIM_LIB ../src/system/sys_clocker.v
vlog -sv +incdir+../src/audio -work $SIM_LIB ../src/system/sys_ticker.v
vlog -sv +incdir+../src/audio -work $SIM_LIB ../src/ui/button_event_handler.v
vlog -sv +incdir+../src/audio -work $SIM_LIB ../src/ui/keyboard_event_handler.v
vlog -sv +incdir+../src/audio -work $SIM_LIB ../src/ui/keyboard_frame_events.v
vlog -sv +incdir+../src/audio -work $SIM_LIB ../src/ui/keyboard_note_pipeline.v
vlog -sv +incdir+../src/audio -work $SIM_LIB ../src/ui/keyboard_voice_allocator.v
vlog -sv +incdir+../src/audio -work $SIM_LIB ../src/ui/knob_event_handler.v
vlog -sv +incdir+../src/audio -work $SIM_LIB ../src/ui/knob_parameter_controller.v
vlog -sv +incdir+../src/audio -work $SIM_LIB ../src/ui/note_frequency_mapper.v
vlog -sv +incdir+../src/audio -work $SIM_LIB ../src/ui/note_pitch_bend.v
vlog -sv +incdir+../src/audio -work $SIM_LIB ../src/ui/note_velocity_controller.v
vlog -sv +incdir+../src/audio -work $SIM_LIB ../src/ui/pitch_bend_controller.v
vlog -sv +incdir+../src/audio -work $SIM_LIB ../src/ui/preset_record_codec.v
vlog -sv +incdir+../src/audio -work $SIM_LIB ../src/ui/ui_control_pipeline.v
vlog -sv +incdir+../src/audio -work $SIM_LIB ../src/ui/ui_control_state.v
vlog -sv +incdir+../src/audio -work $SIM_LIB ../src/ui/ui_display_snapshot.v
vlog -sv +incdir+../src/audio -work $SIM_LIB ../src/ui/ui_input_frame_joiner.v
vlog -sv +incdir+../src/audio -work $SIM_LIB ../src/ui/ui_parameter_encoder.v
vlog -sv +incdir+../src/audio -work $SIM_LIB ../src/ui/ui_preset_controller.v
vlog -sv +incdir+../src/audio -work $SIM_LIB ../src/ui/user_interface.v
vlog -sv +incdir+../src/audio -work $SIM_LIB ../src/test/test_velocity/test_velocity.v
# The local ADC protocol model must take precedence over the vendor empty ADCLRC stub.
vlog -sv -work $SIM_LIB tb/models/adclrc_model.vt
