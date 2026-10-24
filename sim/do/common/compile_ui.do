# UI 公共依赖与业务模块；只列活动源码，不扫描 history。
do compile_phase_accumulator.do
vlog -sv -work $SIM_LIB ../src/audio/phase_accumulator_group.v
vlog -sv -work $SIM_LIB ../src/ui/button_event_handler.v
vlog -sv -work $SIM_LIB ../src/ui/keyboard_event_handler.v
vlog -sv -work $SIM_LIB ../src/ui/keyboard_frame_events.v
vlog -sv -work $SIM_LIB ../src/ui/keyboard_note_pipeline.v
vlog -sv -work $SIM_LIB ../src/ui/keyboard_voice_allocator.v
vlog -sv -work $SIM_LIB ../src/ui/knob_event_handler.v
vlog -sv -work $SIM_LIB ../src/ui/knob_parameter_controller.v
vlog -sv -work $SIM_LIB ../src/ui/note_frequency_mapper.v
vlog -sv -work $SIM_LIB ../src/ui/note_velocity_controller.v
vlog -sv -work $SIM_LIB ../src/ui/preset_record_codec.v
vlog -sv -work $SIM_LIB ../src/ui/ui_control_pipeline.v
vlog -sv -work $SIM_LIB ../src/ui/ui_control_state.v
vlog -sv -work $SIM_LIB ../src/ui/ui_input_frame_joiner.v
vlog -sv -work $SIM_LIB ../src/ui/ui_parameter_encoder.v
vlog -sv -work $SIM_LIB ../src/ui/ui_preset_controller.v
vlog -sv -work $SIM_LIB ../src/ui/user_interface.v
