/**
 * 两路相位累加器组测试平台
 * 观察同频、异频、同步与错开 note_on 的相位波形和握手时序
 */

`timescale 1ps/1ps
`include "../../../src/defines.vh"

module phase_accumulator_group_tb();
    localparam PHASE_ACC_WIDTH = 32;
    localparam CLK_SYS_PERIOD_CNT = 64'd1_000_000_000_000 / `CLK_SYS_FREQ;
    localparam [31:0] PHASE_INCR_K = (64'd1 << PHASE_ACC_WIDTH) / `SMP_TICK_FREQ;
    localparam [31:0] FREQ_C4 = 32'd17145922;  // 261.626 Hz, UQ16.16
    localparam [31:0] FREQ_A4 = 32'd28835840;  // 440 Hz, UQ16.16
    localparam [31:0] FREQ_B5 = 32'd64734298;  // 987.767 Hz, UQ16.16

    reg clk_sys;
    reg rst_n;
    wire smp_tick_up;

    sys_ticker st_u (
        .clk_sys(clk_sys),
        .rst_n(rst_n),
        .i2s_tick_up(),
        .i2s_tick_down(),
        .smp_tick_up(smp_tick_up),
        .smp_tick_down(),
        .scan_tick_up(),
        .scan_tick_down()
    );

    reg [1:0] note_on;
    reg [15:0] init_phase;
    reg [31:0] freq [1:0];
    wire [11:0] out_phase [1:0];
    reg in_valid;
    wire in_ready;
    wire out_valid;
    reg out_ready;

    phase_accumulator_group #(
        .PHASE_ACC_WIDTH(PHASE_ACC_WIDTH),
        .SMP_TICK_FREQ(`SMP_TICK_FREQ),
        .ACCUMULATOR_NUM(2)
    ) pag_u (
        .clk_sys(clk_sys),
        .rst_n(rst_n),
        .smp_tick_up(smp_tick_up),
        .note_on(note_on),
        .init_phase(init_phase),
        .freq(freq),
        .out_phase(out_phase),
        .out_ready(out_ready),
        .in_valid(in_valid),
        .out_valid(out_valid),
        .in_ready(in_ready)
    );

    // Expose the lane handshake signals in the top-level Wave window.
    wire [1:0] lane_out_valid = pag_u.out_valids;
    wire lane_out_ready = pag_u.out_ready_w;

    initial
    begin
        clk_sys = 1'b0;
        forever
        begin
            #(CLK_SYS_PERIOD_CNT / 2);
            clk_sys = ~clk_sys;
        end
    end

    integer error_count;
    integer sample_count;
    integer group_transfer_count;
    integer partial_valid_count;
    integer sample_index;
    reg [1:0] scenario_id;  // 1: same/sync, 2: same/staggered, 3: different/sync
    reg [31:0] expected_phase [1:0];

    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
            group_transfer_count <= 0;
        else if (out_valid && out_ready)
            group_transfer_count <= group_transfer_count + 1;
    end

    function [31:0] calc_increment;
        input [31:0] freq_code;
        reg [63:0] product;
        begin
            product = PHASE_INCR_K * freq_code;
            calc_increment = (product + 64'd32768) >> 16;
        end
    endfunction

    function [11:0] calc_out_phase;
        input [31:0] phase_code;
        begin
            if (phase_code[31:20] == 12'hfff)
                calc_out_phase = 12'hfff;
            else
                calc_out_phase = phase_code[31:20] + phase_code[19];
        end
    endfunction

    task send_sample;
        input [1:0] new_note_on;
        input [31:0] freq_0;
        input [31:0] freq_1;
        input integer input_delay;
        input integer output_stall;
        integer wait_cycles;
        integer old_transfer_count;
        integer i;
        reg [11:0] held_0;
        reg [11:0] held_1;
        begin
            @(posedge smp_tick_up);
            @(negedge smp_tick_up);
            @(negedge clk_sys);
            note_on = new_note_on;
            freq[0] = freq_0;
            freq[1] = freq_1;
            out_ready = (output_stall == 0);
            old_transfer_count = group_transfer_count;

            for (i = 0; i < input_delay; i = i + 1)
            begin
                if (in_ready !== 1'b1 || out_valid !== 1'b0)
                begin
                    error_count = error_count + 1;
                    $display("FAIL input wait: scenario=%0d, sample=%0d, time=%0t",
                             scenario_id, sample_count, $time);
                end
                @(negedge clk_sys);
            end

            if (in_ready !== 1'b1)
            begin
                error_count = error_count + 1;
                $display("FAIL input ready: scenario=%0d, sample=%0d, time=%0t",
                         scenario_id, sample_count, $time);
            end

            expected_phase[0] = new_note_on[0] ? 32'd0 :
                                expected_phase[0] + calc_increment(freq_0);
            expected_phase[1] = new_note_on[1] ? 32'd0 :
                                expected_phase[1] + calc_increment(freq_1);
            in_valid = 1'b1;

            @(posedge clk_sys);
            #1;
            if (in_ready !== 1'b0)
            begin
                error_count = error_count + 1;
                $display("FAIL input handshake: ready stayed high at sample %0d",
                         sample_count);
            end
            @(negedge clk_sys);
            in_valid = 1'b0;
            note_on = 2'b00;

            wait_cycles = 0;
            while (out_valid !== 1'b1 && wait_cycles < 16)
            begin
                if (lane_out_valid == 2'b01 || lane_out_valid == 2'b10)
                begin
                    partial_valid_count = partial_valid_count + 1;
                    if (lane_out_ready !== 1'b0)
                    begin
                        error_count = error_count + 1;
                        $display("FAIL partial output was released at sample %0d",
                                 sample_count);
                    end
                end
                @(negedge clk_sys);
                wait_cycles = wait_cycles + 1;
            end
            if (out_valid !== 1'b1)
            begin
                error_count = error_count + 1;
                $display("FAIL output timeout: scenario=%0d, sample=%0d",
                         scenario_id, sample_count);
                $stop;
            end

            if (out_phase[0] !== calc_out_phase(expected_phase[0]) ||
                out_phase[1] !== calc_out_phase(expected_phase[1]))
            begin
                error_count = error_count + 1;
                $display("FAIL phase: scenario=%0d, sample=%0d, expected=%03h/%03h, actual=%03h/%03h",
                         scenario_id, sample_count,
                         calc_out_phase(expected_phase[0]),
                         calc_out_phase(expected_phase[1]),
                         out_phase[0], out_phase[1]);
            end

            if (output_stall != 0)
            begin
                held_0 = out_phase[0];
                held_1 = out_phase[1];
                for (i = 0; i < output_stall; i = i + 1)
                begin
                    @(negedge clk_sys);
                    if (out_valid !== 1'b1 || lane_out_ready !== 1'b0 ||
                        out_phase[0] !== held_0 || out_phase[1] !== held_1)
                    begin
                        error_count = error_count + 1;
                        $display("FAIL output stall: scenario=%0d, sample=%0d",
                                 scenario_id, sample_count);
                    end
                end
                out_ready = 1'b1;
            end

            @(posedge clk_sys);
            #1;
            if (out_valid !== 1'b0 ||
                group_transfer_count !== old_transfer_count + 1)
            begin
                error_count = error_count + 1;
                $display("FAIL output handshake: scenario=%0d, sample=%0d",
                         scenario_id, sample_count);
            end
            sample_count = sample_count + 1;
            @(negedge clk_sys);
        end
    endtask

    initial
    begin
        error_count = 0;
        sample_count = 0;
        partial_valid_count = 0;
        scenario_id = 0;
        expected_phase[0] = 0;
        expected_phase[1] = 0;
        rst_n = 1'b0;
        note_on = 2'b00;
        init_phase = 16'h0000;
        freq[0] = 0;
        freq[1] = 0;
        in_valid = 1'b0;
        out_ready = 1'b1;
        #20_000;

        if (in_ready !== 1'b0 || out_valid !== 1'b0 ||
            out_phase[0] !== 12'h000 || out_phase[1] !== 12'h000)
        begin
            error_count = error_count + 1;
            $display("FAIL reset");
        end
        rst_n = 1'b1;

        // Both lanes start together at A4; observe a complete ramp.
        scenario_id = 2'd1;
        send_sample(2'b11, FREQ_A4, FREQ_A4, 3, 4);
        for (sample_index = 1; sample_index <= 112; sample_index = sample_index + 1)
            send_sample(2'b00, FREQ_A4, FREQ_A4,
                        (sample_index % 32 == 0) ? 3 : 0,
                        (sample_index % 16 == 0) ? 4 : 0);
        $display("PASS scenario 1: simultaneous note_on, same frequency");

        // Each lane starts a new note on a different sample tick.
        scenario_id = 2'd2;
        for (sample_index = 0; sample_index < 140; sample_index = sample_index + 1)
            send_sample(sample_index == 0 ? 2'b01 :
                        sample_index == 24 ? 2'b10 : 2'b00,
                        FREQ_A4, FREQ_A4,
                        (sample_index == 0 || sample_index == 24) ? 3 : 0,
                        (sample_index % 20 == 0) ? 4 : 0);
        $display("PASS scenario 2: staggered note_on, same frequency");

        // Both lanes restart together, now at two different frequencies.
        scenario_id = 2'd3;
        send_sample(2'b11, FREQ_C4, FREQ_B5, 3, 4);
        for (sample_index = 1; sample_index <= 185; sample_index = sample_index + 1)
            send_sample(2'b00, FREQ_C4, FREQ_B5,
                        (sample_index % 32 == 0) ? 3 : 0,
                        (sample_index % 16 == 0) ? 4 : 0);
        $display("PASS scenario 3: simultaneous note_on, different frequencies");

        if (partial_valid_count == 0)
        begin
            error_count = error_count + 1;
            $display("FAIL no partial lane-valid interval was observed");
        end
        if (group_transfer_count != sample_count)
        begin
            error_count = error_count + 1;
            $display("FAIL group transfer total: samples=%0d, transfers=%0d",
                     sample_count, group_transfer_count);
        end
        $display("PHASE_ACCUMULATOR_GROUP_TB: %0d samples, %0d group transfers, %0d partial-valid clocks, %0d errors",
                 sample_count, group_transfer_count, partial_valid_count,
                 error_count);
        $stop;  // Leave the GUI waveform available for inspection.
    end
endmodule
