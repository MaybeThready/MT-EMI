# UQ1.15 gain migration regression. Run from sim.
onerror {quit -code 1 -force}
onbreak {resume}
file mkdir user_interface/results
set SIM_LIB work_gain_q15
do do/common/setup.do
file mkdir user_interface/results
do do/common/compile_ui.do
foreach item {
    {ui preset_record_codec}
    {ui ui_preset_controller}
    {ui knob_parameter_controller}
    {ui ui_parameter_encoder}
    {ui ui_control_pipeline}
    {ui knob_parameter_s2}
    {ui user_interface_s2}
} {
    lassign $item category module
    vlog -sv -work $SIM_LIB tb/$category/${module}_tb.vt
    vsim -t 1ps -onfinish stop -voptargs=+acc +ASSETS=../assets/ui/test_vectors/control +RESULTS=user_interface/results -wlf user_interface/results/gain_q15_${module}.wlf $SIM_LIB.${module}_tb
    run -all
    if {$module in {knob_parameter_s2 user_interface_s2}} {
        if {[examine -radix unsigned sim:/${module}_tb/test_passed] != 1} {quit -code 1 -force}
    }
    quit -sim
}
echo GAIN_Q15_REGRESSION_COMPLETE
quit -code 0 -force
