# 批量自检入口。Tcl 错误停止；$finish 正常返回，须同时核对每项 PASS 与 Errors=0。
onerror {quit -code 1 -force}
onbreak {}
do run_pitch_bend_controller.do
do run_note_pitch_bend.do
foreach voices {1 3} {
    quit -sim
    vsim -t 1ps -onfinish stop -wlf work_note_pitch_bend_tb/results/voices_${voices}.wlf -gMAX_POLYPHONY=$voices work_note_pitch_bend_tb.note_pitch_bend_tb
    run -all
}
quit -sim
do run_user_interface_pitch_bend.do
echo "PITCH_BEND_UNIT_SCRIPTS_COMPLETED"
