do compile_envelope.do
vlog -work $SIM_LIB ../src/adsr_division/adsr_division.vo

vlog -sv -work $SIM_LIB ../src/audio/phase_accumulator.v
vlog -sv -work $SIM_LIB ../src/audio/phase_accumulator_group.v
vlog -sv -work $SIM_LIB ../src/audio/envelope_group.v

vlog -sv -work $SIM_LIB ../src/fixed_points/signed_fp_norm.v
vlog -sv -work $SIM_LIB ../src/fixed_points/signed_fp_op.v
vlog -sv -work $SIM_LIB ../src/rom_wavetables/rom_wavetables.v
vlog -sv -work $SIM_LIB ../src/audio/wavetable_interpolation.v
vlog -sv -work $SIM_LIB ../src/audio/wavetable_synthesizer.v
vlog -sv -work $SIM_LIB ../src/audio/channel_rack.v
