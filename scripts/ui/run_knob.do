# 由 PowerShell 入口传入路径；不依赖个人电脑路径或旧调试源码。
onerror {quit -f -code 1}
if {![info exists env(MT_EMI_UI_REPO)] || ![info exists env(MT_EMI_UI_RUN)]} {error "Use matching ps1 launcher"}
set repo_dir [file normalize $env(MT_EMI_UI_REPO)]
set run_dir [file normalize $env(MT_EMI_UI_RUN)]
set allowed [file normalize [file join $repo_dir ai_workspace validation ui]]
if {[string first "${allowed}/" "${run_dir}/"] != 0} {error "Invalid output directory"}
set build_dir [file join $run_dir work]
set results_dir [file join $run_dir results]
set assets_dir [file join $repo_dir assets ui test_vectors]
cd $build_dir
vmap -c
set env(MODELSIM) [file join $build_dir modelsim.ini]
vlib work
vmap work work
vlog -sv +incdir+[file join $repo_dir src audio] +incdir+[file join $repo_dir src system] \
    [file join $repo_dir src common fsm.v] \
    [file join $repo_dir src common clock_divider.v] \
    [file join $repo_dir src signal_detection signal_edge_detector.v] \
    [file join $repo_dir src system sys_ticker.v] \
    [file join $repo_dir src fixed_points unsigned_fp_norm.v] \
    [file join $repo_dir src fixed_points unsigned_fp_op.v] \
    [file join $repo_dir src audio phase_accumulator.v] \
    [file join $repo_dir src audio phase_accumulator_group.v] \
    {*}[glob [file join $repo_dir src ui *.v]] \
    {*}[glob [file join $repo_dir sim tb ui *.vt]]
foreach knob_num {1 3 8 16} {
    foreach seed {20261017 9137} {
        vsim -onfinish stop -wlf [file join $results_dir knob_${knob_num}_${seed}.wlf] \
            -gKNOB_NUM=$knob_num -gSEED=$seed work.knob_event_handler_tb
        log -r /*
        run -all
        quit -sim
    }
}
quit -f -code 0
