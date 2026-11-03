do do/common/compile_chord.do
vlog -sv -work $SIM_LIB ../src/audio/channel_rack.v
vlog -sv -work $SIM_LIB ../src/audio/envelope.v
vlog -sv -work $SIM_LIB ../src/audio/envelope_group.v
vlog -sv -work $SIM_LIB ../src/audio/phase_accumulator.v
vlog -sv -work $SIM_LIB ../src/audio/phase_accumulator_group.v
vlog -sv -work $SIM_LIB ../src/audio/detuned_phase_group.v
vlog -sv -work $SIM_LIB ../src/audio/wavetable_interpolation.v
vlog -sv -work $SIM_LIB ../src/audio/wavetable_synthesizer.v
vlog -sv -work $SIM_LIB ../src/mixer/chorus.v
vlog -sv -work $SIM_LIB ../src/mixer/delay.v
vlog -sv -work $SIM_LIB ../src/mixer/distortion.v
vlog -sv -work $SIM_LIB ../src/mixer/mixer.v
vlog -sv -work $SIM_LIB ../src/mixer/reverb.v
vlog -sv -work $SIM_LIB tb/audio/adsr_division_functional.vt tb/audio/memory_functional.vt tb/audio/memory_ip_aliases.vt
