`timescale 1ps/1ps

`include "../../../src/defines.vh"

module phase_accumulator_tb();
    localparam PHASE_ACC_WIDTH = 32;
    localparam CLK_SYS_PERIOD_CNT = 64'd1_000_000_000_000 / `CLK_SYS_FREQ;
    localparam [31:0] PHASE_INCR_K = (64'd1 << PHASE_ACC_WIDTH) / `SMP_TICK_FREQ;
    localparam MAX_PERIOD_SAMPLES = 240;

    localparam [31:0] FREQ_C4 = 32'd17145922;  // 261.626 Hz, UQ16.16
    localparam [31:0] FREQ_A4 = 32'd28835840;  // 440 Hz, UQ16.16
    localparam [31:0] FREQ_B5 = 32'd64734298;  // 987.767 Hz, UQ16.16

    reg clk_sys;
    reg rst_n;
    wire smp_tick_up;

    sys_ticker st_u
    (
        .clk_sys(clk_sys),
        .rst_n(rst_n),
        .i2s_tick_up(),
        .i2s_tick_down(),
        .smp_tick_up(smp_tick_up),
        .smp_tick_down(),
        .scan_tick_up(),
        .scan_tick_down()
    );

    reg note_on;
    reg [15:0] init_phase;
    reg [31:0] freq;
    wire [11:0] out_phase;

    reg in_valid;
    reg out_ready;
    wire out_valid;
    wire in_ready;

    phase_accumulator #(
        .PHASE_ACC_WIDTH(PHASE_ACC_WIDTH),
        .SMP_TICK_FREQ(`SMP_TICK_FREQ)
    ) pa_u (
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
    integer transaction_count;
    integer backpressure_count;
    reg [1:0] period_id;  // 1: C4, 2: A4, 3: B5
    reg [31:0] expected_phase;
    reg [11:0] held_phase;
    time last_output_ps;

    // The multiplier rounds UQ16.48 to UQ0.32.
    function [31:0] calc_increment;
        input [31:0] freq_code;
        reg [63:0] product;
        begin
            product = PHASE_INCR_K * freq_code;
            calc_increment = (product + 64'd32768) >> 16;
        end
    endfunction

    // The normalizer rounds UQ0.32 to UQ0.12.
    function [11:0] calc_out_phase;
        input [31:0] phase_code;
        begin
            if (phase_code[31:20] == 12'hfff)
                calc_out_phase = 12'hfff;
            else
                calc_out_phase = phase_code[31:20] + phase_code[19];
        end
    endfunction

    // One transaction per sample tick. Check the input handshake, output
    // value, and the output handshake (including a deliberate stall).
    task send_sample;
        input [8*8-1:0] note_name;
        input new_note_on;
        input [31:0] new_freq;
        input hold_output;
        integer wait_cycles;
        begin
            @(posedge smp_tick_up);
            @(negedge smp_tick_up);
            @(negedge clk_sys);
            note_on = new_note_on;
            init_phase = 16'h0000;
            freq = new_freq;
            out_ready = !hold_output;
            if (in_ready !== 1'b1 || out_valid !== 1'b0)
            begin
                error_count = error_count + 1;
                $display("FAIL %0s: input not ready before transfer, time=%0t",
                         note_name, $time);
            end
            in_valid = 1'b1;

            // valid and ready are both high at this rising edge.
            @(posedge clk_sys);
            #1;
            if (in_ready !== 1'b0)
            begin
                error_count = error_count + 1;
                $display("FAIL %0s: in_ready did not clear after transfer", note_name);
            end
            @(negedge clk_sys);
            in_valid = 1'b0;
            note_on = 1'b0;

            wait_cycles = 0;
            while (out_valid !== 1'b1 && wait_cycles < 16)
            begin
                @(negedge clk_sys);
                wait_cycles = wait_cycles + 1;
            end
            if (out_valid !== 1'b1)
            begin
                error_count = error_count + 1;
                $display("FAIL %0s: out_valid timeout, time=%0t", note_name, $time);
            end
            else
            begin
                transaction_count = transaction_count + 1;
                last_output_ps = $time;
                if (out_phase !== calc_out_phase(expected_phase))
                begin
                    error_count = error_count + 1;
                    $display("FAIL %0s sample %0d: expected=%03h, actual=%03h",
                             note_name, transaction_count,
                             calc_out_phase(expected_phase), out_phase);
                end
            end

            if (hold_output)
            begin
                backpressure_count = backpressure_count + 1;
                held_phase = out_phase;
                repeat (3)
                begin
                    @(negedge clk_sys);
                    if (out_valid !== 1'b1 || out_phase !== held_phase ||
                        in_ready !== 1'b0)
                    begin
                        error_count = error_count + 1;
                        $display("FAIL %0s: output changed during backpressure",
                                 note_name);
                    end
                end
                out_ready = 1'b1;
            end

            repeat (3) @(negedge clk_sys);
            if (out_valid !== 1'b0 || in_ready !== 1'b1)
            begin
                error_count = error_count + 1;
                $display("FAIL %0s: handshake did not complete", note_name);
            end
        end
    endtask

    // Start at phase zero and stop immediately after the first wrap.
    // Stall one output in every 16 samples without losing the phase ramp.
    task run_period;
        input [8*8-1:0] note_name;
        input [1:0] new_period_id;
        input [31:0] new_freq;
        integer sample_count;
        reg [11:0] previous_phase;
        reg wrapped;
        time period_start_ps;
        real measured_freq;
        begin
            period_id = new_period_id;
            expected_phase = '0;
            send_sample(note_name, 1'b1, new_freq, 1'b1);
            period_start_ps = last_output_ps;
            previous_phase = out_phase;
            sample_count = 0;
            wrapped = 1'b0;

            while (!wrapped && sample_count < MAX_PERIOD_SAMPLES)
            begin
                expected_phase = expected_phase + calc_increment(new_freq);
                sample_count = sample_count + 1;
                send_sample(note_name, 1'b0, new_freq,
                            (sample_count % 16) == 0);
                if (out_phase < previous_phase)
                    wrapped = 1'b1;
                previous_phase = out_phase;
            end

            if (!wrapped)
            begin
                error_count = error_count + 1;
                $display("FAIL %0s: no phase wrap within %0d samples",
                         note_name, MAX_PERIOD_SAMPLES);
            end
            else
            begin
                measured_freq = 1.0e12 / (last_output_ps - period_start_ps);
                $display("%0s: one period, %0d samples, cursor estimate=%0.3f Hz",
                         note_name, sample_count, measured_freq);
            end
        end
    endtask

    initial
    begin
        error_count = 0;
        transaction_count = 0;
        backpressure_count = 0;
        expected_phase = '0;
        last_output_ps = 0;
        period_id = 0;
        freq = '0;
        init_phase = '0;
        note_on = 1'b0;
        in_valid = 1'b0;
        out_ready = 1'b1;
        rst_n = 1'b0;
        #20_000;

        if (out_phase !== 12'h000 || out_valid !== 1'b0 ||
            in_ready !== 1'b0)
        begin
            error_count = error_count + 1;
            $display("FAIL reset: outputs did not clear");
        end
        rst_n = 1'b1;

        run_period("C4", 2'd1, FREQ_C4);
        run_period("A4", 2'd2, FREQ_A4);
        run_period("B5", 2'd3, FREQ_B5);

        $display("PHASE_ACCUMULATOR_TB: %0d transactions, %0d stalls, %0d errors",
                 transaction_count, backpressure_count, error_count);
        $stop;  // Keep the GUI waveform available for cursor measurements.
    end
endmodule

