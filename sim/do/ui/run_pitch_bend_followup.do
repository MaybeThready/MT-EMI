# 新增弯音后需要重新确认的系统延迟、相位依赖与保存读取。
onerror {quit -code 1 -force}
onbreak {}
do run_keyboard_phase_integration.do
do run_user_interface_system.do
do run_user_interface_system_seed2026.do
do run_user_interface_system_seed9321.do
do run_user_interface_preset.do
echo "PITCH_BEND_FOLLOWUP_COMPLETED"
