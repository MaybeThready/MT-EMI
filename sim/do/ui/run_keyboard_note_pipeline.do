# 工作目录设为 sim，再通过 Execute Macro 执行；结束后保留波形。
set SIM_LIB work_keyboard_note_pipeline_tb
do ../common/setup.do
file mkdir $SIM_LIB/results
do ../common/compile_ui.do
vlog -sv -work $SIM_LIB tb/ui/keyboard_note_pipeline_tb.vt
vsim -t 1ps -onfinish stop -voptargs=+acc -wlf $SIM_LIB/results/keyboard_note_pipeline_tb.wlf +ASSETS=../assets/ui/test_vectors/control +RESULTS=$SIM_LIB/results $SIM_LIB.keyboard_note_pipeline_tb
do wave_keyboard_note_pipeline.do
run -all
