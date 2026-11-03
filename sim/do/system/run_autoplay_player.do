onerror {quit -code 1 -force}
set SIM_LIB work_autoplay_player
do do/common/setup.do
do do/common/setup_gowin.do
file mkdir $SIM_LIB/results
foreach source {../src/system/autoplay_event_rom.v ../src/system/autoplay_frequency_lut.v ../src/system/autoplay_player.v tb/system/autoplay_player_tb.vt} {
    vlog -sv -work $SIM_LIB +incdir+../src $source
}
vsim -L gw5a -t 1ps -onfinish stop -voptargs=+acc \
    -wlf $SIM_LIB/results/autoplay_player.wlf $SIM_LIB.autoplay_player_tb
run -all
if {[examine -radix unsigned sim:/autoplay_player_tb/test_passed] != 1} {error "AutoPlay player test failed"}
quit -f
