# Validate that the delivered MPF opens and compiles from the formal sim/.
onerror {quit -code 1 -force}
do do/common/setup_gowin.do
if {![file isdirectory work]} {vlib work}
project open MT-EMI
project compileall
echo LCD_FORMAL_MPF_COMPILE_PASS
project close
quit -code 0 -force
