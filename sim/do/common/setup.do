# Run the entry scripts with ModelSim's current directory set to sim/.
# Keep one compiled library per testbench so old modules cannot mask a missing dependency.
catch {quit -sim}
if {[file isdirectory $SIM_LIB]} {
    vdel -lib $SIM_LIB -all
}
vlib $SIM_LIB

