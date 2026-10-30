/**
 * 上板测试 1：相位累加器读取正弦波 ROM，输出 440 Hz I2S 音频。
 * 音频采样先保存在单槽缓冲中，再由 I2S 在帧起点取走。
 */
module test_i2s
(
    input clk_core,
    input rst_n,
    input data_a,
    input data_b,
    output load_n,
    output key_clk,
    output i2s_bclk,
    output i2s_lrck,
    output i2s_dout,
    output sd_mode_n,
    output [1:0] status_led
);
    wire clk_sys, rst_sys_n;
    wire i2s_tick_up, i2s_tick_down, smp_tick_up;
    sys_clocker sys_clocker_u (
        .clk_core(clk_core), .rst_n(rst_n),
        .clk_sys(clk_sys), .rst_sys_n(rst_sys_n)
    );
    sys_ticker sys_ticker_u (
        .clk_sys(clk_sys), .rst_n(rst_sys_n),
        .i2s_tick_up(i2s_tick_up), .i2s_tick_down(i2s_tick_down),
        .smp_tick_up(smp_tick_up), .smp_tick_down(),
        .scan_tick_up(), .scan_tick_down()
    );

    wire [11:0] phase;
    wire phase_in_ready, phase_out_valid;
    wire phase_out_ready;
    reg note_started_r;
    phase_accumulator phase_accumulator_u (
        .clk_sys(clk_sys), .rst_n(rst_sys_n), .smp_tick_up(smp_tick_up),
        .note_on(!note_started_r), .init_phase(16'd0),
        .freq(32'd28_835_840),  // 440 Hz，UQ16.16
        .out_phase(phase), .out_ready(phase_out_ready),
        .in_valid(1'b1), .out_valid(phase_out_valid), .in_ready(phase_in_ready)
    );

    localparam WAIT_PHASE = 2'd0, READ_ROM = 2'd1,
               CAPTURE_ROM = 2'd2, WAIT_BUFFER = 2'd3;
    reg [1:0] stc;
    reg [13:0] rom_addr_r;
    wire [15:0] rom_data;
    reg signed [15:0] pending_sample_r;
    reg signed [15:0] sample_r;
    reg sample_valid_r;
    wire i2s_ready;

    rom_wavetables rom_wavetables_u (
        .dout(rom_data), .clk(clk_sys), .oce(1'b1), .ce(1'b1),
        .reset(1'b0), .ad(rom_addr_r)
    );

    assign phase_out_ready = (stc == WAIT_PHASE);
    always @(posedge clk_sys or negedge rst_sys_n)
    begin
        if (!rst_sys_n)
        begin
            note_started_r <= 1'b0;
            stc <= WAIT_PHASE;
            rom_addr_r <= 14'd0;
            pending_sample_r <= 16'sd0;
            sample_r <= 16'sd0;
            sample_valid_r <= 1'b0;
        end
        else
        begin
            if (phase_in_ready)
                note_started_r <= 1'b1;
            if (sample_valid_r && i2s_ready)
                sample_valid_r <= 1'b0;

            case (stc)
                WAIT_PHASE:
                begin
                    if (phase_out_valid)
                    begin
                        rom_addr_r <= {2'b00, phase};
                        stc <= READ_ROM;
                    end
                end
                READ_ROM: stc <= CAPTURE_ROM;
                CAPTURE_ROM:
                begin
                    pending_sample_r <= $signed(rom_data);
                    stc <= WAIT_BUFFER;
                end
                WAIT_BUFFER:
                begin
                    if (!sample_valid_r || i2s_ready)
                    begin
                        sample_r <= pending_sample_r;
                        sample_valid_r <= 1'b1;
                        stc <= WAIT_PHASE;
                    end
                end
                default: stc <= WAIT_PHASE;
            endcase
        end
    end

    i2s_driver i2s_driver_u (
        .clk_sys(clk_sys), .rst_n(rst_sys_n),
        .i2s_tick_up(i2s_tick_up), .i2s_tick_down(i2s_tick_down),
        .smp_tick_up(smp_tick_up), .audio_data(sample_r),
        .in_valid(sample_valid_r), .in_ready(i2s_ready),
        .audio_out_lcd(), .out_valid_lcd(), .out_ready_lcd(1'b1),
        .i2s_bclk(i2s_bclk), .i2s_lrck(i2s_lrck),
        .i2s_dout(i2s_dout), .sd_mode_n(sd_mode_n)
    );
    assign load_n = 1'b1;
    assign key_clk = 1'b0;

    reg [15:0] frame_count_r;
    reg underrun_r, sample_seen_r, output_started_r;
    always @(posedge clk_sys or negedge rst_sys_n)
    begin
        if (!rst_sys_n)
        begin
            frame_count_r <= 16'd0;
            underrun_r <= 1'b0;
            sample_seen_r <= 1'b0;
            output_started_r <= 1'b0;
        end
        else
        begin
            if (sample_valid_r && i2s_ready)
                output_started_r <= 1'b1;
            if (smp_tick_up)
            begin
                frame_count_r <= frame_count_r + 1'b1;
                if (output_started_r && !sample_seen_r &&
                    !(sample_valid_r && i2s_ready))
                    underrun_r <= 1'b1;
                sample_seen_r <= sample_seen_r && sample_valid_r && i2s_ready;
            end
            else if (sample_valid_r && i2s_ready)
                sample_seen_r <= 1'b1;
        end
    end
    assign status_led = {underrun_r, frame_count_r[14]};
endmodule
