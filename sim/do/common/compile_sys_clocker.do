vlog -sv -work $SIM_LIB ../src/signal_detection/signal_sync.v
vlog -sv -work $SIM_LIB ../src/pll_init.v
vlog -sv -work $SIM_LIB ../src/gowin_pll/gowin_pll_mod.v
vlog -sv -work $SIM_LIB ../src/gowin_pll/gowin_pll.v
vlog -sv -work $SIM_LIB ../src/system/sys_clocker.v

