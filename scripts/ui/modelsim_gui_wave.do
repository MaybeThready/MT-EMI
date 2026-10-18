# Simulation 项加载后执行；保留窗口，并把本次结果归档到 ai_workspace。
proc ui_gui_run {top label} {
    set root [file normalize ..]
    set base [file join $root ai_workspace modelsim_project]
    set stamp "[clock format [clock seconds] -format %Y%m%d_%H%M%S]_[clock clicks]"
    set result [file join $base history ${label}_${stamp}]
    file mkdir $result
    transcript file [file join $result modelsim.log]
    puts "UI_GUI_START top=$top result=$result"
    onfinish stop
    log /$top/*
    # 系统测试时间较长，只默认记录公开信号和顶层内部信号。
    # +acc 保留内部可见性，进一步调试时可在运行前添加所需节点。
    if {$top eq "user_interface_system_tb"} {
        log /$top/user_interface_u/*
        log -r /$top/user_interface_u/note_freq
        log -r /$top/user_interface_u/note_velocity
    } else {
        log -r /$top/*
    }
    if {![batch_mode]} {
        view wave
        catch {delete wave *}
        foreach {group patterns} {
            Clock_Reset {clk_sys rst_n smp_tick_up scan_tick_up}
            Handshake {in_valid in_ready out_valid out_ready configuration_error sample_overrun}
            Keyboard {key_states key_velocity note_busy note_on note_off note_freq note_velocity}
            Controls {button_states knob_states knob_dirs knob_pressed knob_delta mode fine_adjust}
            Audio_Parameters {wavetable_0 wavetable_1 wavetable_interp init_phase attack_ticks decay_ticks sustain_level release_ticks master_volume reverb_mix delay_mix distortion_mix chorus_mix}
        } {
            foreach signal $patterns {
                catch {add wave -group $group -radix unsigned /$top/$signal}
            }
        }
        # 各单元 TB 名称不同，额外保留顶层信号，内部节点可在 Objects 中继续加入。
        catch {add wave -group TB -radix hexadecimal /$top/*}
    }
    run -all
    dataset save sim [file join $result waves.wlf]
    if {$top eq "user_interface_system_tb"} {
        set seed 1018
        if {[regexp {seed([0-9]+)$} $label -> configured_seed]} {set seed $configured_seed}
        set csv [file join $base results system_${seed}.csv]
        if {[file exists $csv]} {file copy -force $csv $result}
    }
    puts "UI_GUI_FINISHED top=$top history=$result (check the TB PASS marker)"
    if {![batch_mode]} {wave zoom full}
}
