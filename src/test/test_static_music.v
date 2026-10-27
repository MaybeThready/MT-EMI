/**
 * 上板测试 2：单声部通道机架循环演奏小星星短句。
 * 七个音符后留一拍休止；短释放时间避免相邻音符重叠。
 */
module test_static_music
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
    localparam [13:0] STEP_SAMPLES = 14'd12_000;  // 250 ms
    localparam [13:0] GATE_SAMPLES = 14'd10_800;  // 留 25 ms 换音间隙

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

    function [31:0] melody_freq;
        input [2:0] note_index;
        begin
            case (note_index)
                3'd0, 3'd1: melody_freq = 32'd17_145_893; // C4
                3'd2, 3'd3, 3'd6: melody_freq = 32'd25_689_813; // G4
                3'd4, 3'd5: melody_freq = 32'd28_835_840; // A4
                default: melody_freq = 32'd17_145_893;
            endcase
        end
    endfunction

    reg [13:0] step_sample_r;
    reg [2:0] note_index_r;
    wire rack_in_ready, rack_out_valid, rack_out_ready;
    wire note_busy;
    wire signed [15:0] rack_audio;
    wire [31:0] note_freq [0:0];
    wire [15:0] note_velocity [0:0];
    assign note_freq[0] = melody_freq(note_index_r);
    assign note_velocity[0] = 16'hc000;
    wire note_on = (step_sample_r == 14'd0) && (note_index_r != 3'd7);
    wire note_off = (step_sample_r == GATE_SAMPLES) && (note_index_r != 3'd7);

    channel_rack #(
        .MAX_POLYPHONY(1)
    ) channel_rack_u (
        .clk_sys(clk_sys), .rst_n(rst_sys_n), .smp_tick_up(smp_tick_up),
        .note_on(note_on), .note_off(note_off), .note_busy(note_busy),
        .note_freq(note_freq), .note_velocity(note_velocity),
        .init_phase(16'd0), .attack_ticks(20'd48),
        .decay_ticks(20'd48), .sustain_level(16'hb000),
        .release_ticks(20'd240),
        .wavetable_0(4'd0), .wavetable_1(4'd0),
        .wavetable_interp(16'd0),
        .audio_out(rack_audio), .out_ready(rack_out_ready),
        .in_valid(1'b1), .out_valid(rack_out_valid), .in_ready(rack_in_ready)
    );

    // 每次机架真正接收一个采样，乐句才向前推进。
    always @(posedge clk_sys or negedge rst_sys_n)
    begin
        if (!rst_sys_n)
        begin
            step_sample_r <= 14'd0;
            note_index_r <= 3'd0;
        end
        else if (rack_in_ready)
        begin
            if (step_sample_r == STEP_SAMPLES - 1'b1)
            begin
                step_sample_r <= 14'd0;
                note_index_r <= note_index_r + 1'b1;
            end
            else
                step_sample_r <= step_sample_r + 1'b1;
        end
    end

    reg signed [15:0] sample_r;
    reg sample_valid_r, output_started_r, underrun_r;
    reg [15:0] frame_count_r;
    wire i2s_ready;
    assign rack_out_ready = !sample_valid_r;
    always @(posedge clk_sys or negedge rst_sys_n)
    begin
        if (!rst_sys_n)
        begin
            sample_r <= 16'sd0;
            sample_valid_r <= 1'b0;
            output_started_r <= 1'b0;
            underrun_r <= 1'b0;
            frame_count_r <= 16'd0;
        end
        else
        begin
            if (i2s_ready)
            begin
                sample_valid_r <= 1'b0;
                frame_count_r <= frame_count_r + 1'b1;
                if (output_started_r && !sample_valid_r)
                    underrun_r <= 1'b1;
            end
            if (rack_out_valid && rack_out_ready)
            begin
                sample_r <= rack_audio;
                sample_valid_r <= 1'b1;
                output_started_r <= 1'b1;
            end
        end
    end

    i2s_driver i2s_driver_u (
        .clk_sys(clk_sys), .rst_n(rst_sys_n),
        .i2s_tick_up(i2s_tick_up), .i2s_tick_down(i2s_tick_down),
        .smp_tick_up(smp_tick_up), .audio_data(sample_r),
        .in_valid(sample_valid_r), .in_ready(i2s_ready),
        .i2s_bclk(i2s_bclk), .i2s_lrck(i2s_lrck),
        .i2s_dout(i2s_dout), .sd_mode_n(sd_mode_n)
    );
    assign load_n = 1'b1;
    assign key_clk = 1'b0;
    assign status_led = {underrun_r, frame_count_r[14]};
endmodule
