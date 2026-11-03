# Formal maintained UI/audio chord suite. Diagnostic tops are not part of it.
onerror {quit -code 1 -force}
set CHORD_SUITE 1
do do/audio/run_memory_ip_equivalence.do
do do/ui/run_chord_units.do
do do/ui/run_chord_regression.do
do do/ui/run_chord_audio.do
echo CHORD_FORMAL_UI_PASS
quit -code 0 -force
