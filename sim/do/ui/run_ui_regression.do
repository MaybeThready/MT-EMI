# UI 全套默认配置和弯音；包含三个系统随机种子。工作目录必须为 sim。
onerror {quit -code 1 -force}
onbreak {}
do run_button_event_handler.do
do run_keyboard_event_handler.do
do run_keyboard_frame_events.do
do run_keyboard_note_pipeline.do
do run_keyboard_phase_integration.do
do run_keyboard_voice_allocator.do
do run_knob_event_handler.do
do run_knob_parameter_controller.do
do run_note_frequency_mapper.do
do run_note_velocity_controller.do
do run_ui_control_pipeline.do
do run_ui_control_state.do
do run_ui_input_frame_joiner.do
do run_ui_parameter_encoder.do
do run_user_interface_keyboard.do
do run_user_interface_system.do
do run_user_interface.do
do run_user_interface_system_seed2026.do
do run_user_interface_system_seed9321.do
do run_preset_record_codec.do
do run_ui_preset_controller.do
do run_user_interface_preset.do

# 保留旧批量脚本的参数边界测试；复用各入口刚编译的独立测试库。
proc ui_parameter_case {test args} {
    set lib work_${test}_tb
    vsim -t 1ps -onfinish stop -voptargs=+acc -wlf $lib/results/parameter_case.wlf +ASSETS=../assets/ui/test_vectors/control +RESULTS=$lib/results {*}$args $lib.${test}_tb
    add wave sim:/${test}_tb/*
    run -all
    quit -sim
}
foreach steps {1 2 4} {
    foreach stalled {0 1} {
        ui_parameter_case knob_parameter_controller -gWAVE_SELECT_STEPS=$steps -gSTALL_SNAPSHOT=$stalled
    }
}
foreach steps {0 32768} {
    ui_parameter_case knob_parameter_controller -gWAVE_SELECT_STEPS=$steps
}
foreach hz {48000 44100 47971 1000 209715} {
    ui_parameter_case ui_parameter_encoder -gSMP_TICK_FREQ=$hz
}
foreach keys {1 3 24} {
    ui_parameter_case keyboard_frame_events -gKEY_NUM=$keys
}
foreach knobs {1 3 8 16} {
    foreach seed {20261017 9137} {
        ui_parameter_case knob_event_handler -gKNOB_NUM=$knobs -gSEED=$seed
    }
}
foreach counts {{1 1} {3 1} {3 2} {24 3} {24 32}} {
    lassign $counts keys voices
    foreach test {keyboard_event_handler keyboard_voice_allocator} {
        set lib work_${test}_tb
        vsim -t 1ps -onfinish stop -voptargs=+acc -wlf $lib/results/parameter_case.wlf +ASSETS=../assets/ui/test_vectors/keyboard -gKEY_NUM=$keys -gMAX_POLYPHONY=$voices $lib.${test}_tb
        add wave sim:/${test}_tb/*
        run -all
        quit -sim
    }
}
rename ui_parameter_case {}
do run_pitch_bend_regression.do
echo "UI regression scripts completed; check each TB PASS and error messages."
