# Step2 UI storage regression; run from sim, outputs remain in workspace.
onerror {quit -code 1 -force}
onbreak {resume}
set SIM_LIB work_ui_driver_step2
do do/common/setup.do
file mkdir drivers/results
do do/common/compile_ui.do
vlog -sv -work $SIM_LIB tb/ui/preset_record_codec_tb.vt
vsim -t 1ps -onfinish stop -voptargs=+acc +ASSETS=../assets/ui/test_vectors/control +RESULTS=drivers/results -wlf drivers/results/step2_preset_record_codec.wlf $SIM_LIB.preset_record_codec_tb
run -all
quit -sim
vlog -sv -work $SIM_LIB tb/ui/ui_preset_controller_tb.vt
vsim -t 1ps -onfinish stop -voptargs=+acc +ASSETS=../assets/ui/test_vectors/control +RESULTS=drivers/results -wlf drivers/results/step2_ui_preset_controller.wlf $SIM_LIB.ui_preset_controller_tb
run -all
quit -sim
vlog -sv -work $SIM_LIB tb/ui/knob_parameter_controller_tb.vt
vsim -t 1ps -onfinish stop -voptargs=+acc +ASSETS=../assets/ui/test_vectors/control +RESULTS=drivers/results -wlf drivers/results/step2_knob_parameter_controller.wlf $SIM_LIB.knob_parameter_controller_tb
run -all
quit -sim
vlog -sv -work $SIM_LIB tb/ui/ui_parameter_encoder_tb.vt
vsim -t 1ps -onfinish stop -voptargs=+acc +ASSETS=../assets/ui/test_vectors/control +RESULTS=drivers/results -wlf drivers/results/step2_ui_parameter_encoder.wlf $SIM_LIB.ui_parameter_encoder_tb
run -all
quit -sim
vlog -sv -work $SIM_LIB tb/ui/ui_control_pipeline_tb.vt
vsim -t 1ps -onfinish stop -voptargs=+acc +ASSETS=../assets/ui/test_vectors/control +RESULTS=drivers/results -wlf drivers/results/step2_ui_control_pipeline.wlf $SIM_LIB.ui_control_pipeline_tb
run -all
quit -sim
vlog -sv -work $SIM_LIB tb/ui/user_interface_preset_tb.vt
vsim -t 1ps -onfinish stop -voptargs=+acc +ASSETS=../assets/ui/test_vectors/control +RESULTS=drivers/results -wlf drivers/results/step2_user_interface_preset.wlf $SIM_LIB.user_interface_preset_tb
run -all
quit -sim
quit -code 0 -force
