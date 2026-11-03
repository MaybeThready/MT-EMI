/**
 * AutoPlay audio-frame replacement. MIDI event times are in 48 kHz samples.
 * This module sits between UI and audio_parameter_bridge. It preserves the
 * UI's sample-frame valid/ready cadence and changes only note data; timbre and
 * effect parameters still come from the UI. One ROM read is shared by all
 * voices. Every note_on retains the MIDI 7-bit attack velocity (scaled to
 * UQ0.16). Note-off/Note-on events never share a lane in one frame.
 *
 * Starting or stopping sends one all-note-off frame before switching source.
 * The physical keyboard is held inactive in top while auto_route_active=1.
 */
module autoplay_player #(
    parameter MAX_POLYPHONY = 32,
    parameter AUTO_VOICES = 8
)(
    input clk_sys,
    input rst_n,
    input enable,
    input song_select,
    input ui_valid,
    output ui_ready,
    output out_valid,
    input out_ready,
    input [MAX_POLYPHONY-1:0] ui_note_on,
    input [MAX_POLYPHONY-1:0] ui_note_off,
    input [31:0] ui_note_freq [MAX_POLYPHONY-1:0],
    input [15:0] ui_note_velocity [MAX_POLYPHONY-1:0],
    output [MAX_POLYPHONY-1:0] note_on,
    output [MAX_POLYPHONY-1:0] note_off,
    output [31:0] note_freq [MAX_POLYPHONY-1:0],
    output [15:0] note_velocity [MAX_POLYPHONY-1:0],
    output auto_route_active,
    output reg song_done
);
    localparam ST_BYPASS = 3'd0, ST_CLEAR = 3'd1, ST_WAIT = 3'd2,
               ST_READ = 3'd3, ST_APPLY = 3'd4, ST_SEND = 3'd5,
               ST_FINISHED = 3'd6, ST_STOP = 3'd7;
    reg [2:0] state_r;
    reg song_r;
    reg [10:0] event_index_r;
    reg [20:0] sample_index_r;
    reg [AUTO_VOICES-1:0] on_r, off_r;
    reg [31:0] frequency_r [0:AUTO_VOICES-1];
    reg [15:0] velocity_r [0:AUTO_VOICES-1];
    wire [40:0] event_data;
    wire [10:0] song_start, song_end;
    wire [20:0] song_samples;
    wire [31:0] event_frequency;
    wire [15:0] event_velocity = ({9'd0,event_data[6:0]} << 9) +
                                 ({9'd0,event_data[6:0]} << 2);
    wire [4:0] event_voice = event_data[18:14];
    wire deliver = ui_valid && out_ready && out_valid;
    integer voice;
    genvar lane;

    autoplay_event_rom rom_u (
        .clk_sys(clk_sys), .rst_n(rst_n), .rd_en(state_r == ST_READ),
        .address(event_index_r), .event_data(event_data),
        .song_select(song_r), .song_start(song_start), .song_end(song_end),
        .song_samples(song_samples)
    );
    autoplay_frequency_lut frequency_lut_u (
        .pitch(event_data[13:7]), .frequency(event_frequency)
    );

    assign auto_route_active = enable || (state_r != ST_BYPASS);
    assign out_valid = ui_valid && (
        ((state_r == ST_BYPASS) && !enable) ||
        (state_r == ST_CLEAR) || (state_r == ST_STOP) ||
        (((state_r == ST_SEND) || (state_r == ST_FINISHED)) && enable));
    assign ui_ready = out_valid && out_ready;
    assign note_on = !auto_route_active ? ui_note_on : {MAX_POLYPHONY{1'b0}} |
        {{(MAX_POLYPHONY-AUTO_VOICES){1'b0}},on_r};
    assign note_off = !auto_route_active ? ui_note_off :
        ((state_r == ST_CLEAR || state_r == ST_STOP) ?
         {MAX_POLYPHONY{1'b1}} :
         {{(MAX_POLYPHONY-AUTO_VOICES){1'b0}},off_r});
    generate
        for (lane = 0; lane < MAX_POLYPHONY; lane = lane + 1) begin : output_lanes
            if (lane < AUTO_VOICES) begin
                assign note_freq[lane] = auto_route_active ? frequency_r[lane] : ui_note_freq[lane];
                assign note_velocity[lane] = auto_route_active ? velocity_r[lane] : ui_note_velocity[lane];
            end else begin
                assign note_freq[lane] = auto_route_active ? 32'd0 : ui_note_freq[lane];
                assign note_velocity[lane] = auto_route_active ? 16'd0 : ui_note_velocity[lane];
            end
        end
    endgenerate

    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            state_r <= ST_BYPASS;
            song_r <= 1'b0;
            event_index_r <= 11'd0;
            sample_index_r <= 21'd0;
            on_r <= '0;
            off_r <= '0;
            song_done <= 1'b0;
            for (voice = 0; voice < AUTO_VOICES; voice = voice + 1)
            begin
                frequency_r[voice] <= 32'd0;
                velocity_r[voice] <= 16'd0;
            end
        end
        else
        begin
            song_done <= 1'b0;
            if (!enable && state_r != ST_BYPASS && state_r != ST_STOP)
            begin
                on_r <= '0;
                off_r <= '0;
                state_r <= ST_STOP;
            end
            else case (state_r)
                ST_BYPASS:
                    if (enable)
                    begin
                        song_r <= song_select;
                        on_r <= '0;
                        off_r <= '0;
                        state_r <= ST_CLEAR;
                    end
                ST_CLEAR:
                    if (deliver)
                    begin
                        event_index_r <= song_start;
                        sample_index_r <= 21'd0;
                        on_r <= '0;
                        off_r <= '0;
                        for (voice = 0; voice < AUTO_VOICES; voice = voice + 1)
                        begin
                            frequency_r[voice] <= 32'd0;
                            velocity_r[voice] <= 16'd0;
                        end
                        state_r <= ST_WAIT;
                    end
                ST_WAIT:
                    if (ui_valid)
                        state_r <= (event_index_r < song_end) ? ST_READ : ST_SEND;
                ST_READ: state_r <= ST_APPLY;
                ST_APPLY:
                    if (event_data[40:20] <= sample_index_r)
                    begin
                        if (event_voice < AUTO_VOICES)
                        begin
                            if (event_data[19])
                            begin
                                on_r[event_voice] <= 1'b1;
                                frequency_r[event_voice] <= event_frequency;
                                velocity_r[event_voice] <= event_velocity;
                            end
                            else off_r[event_voice] <= 1'b1;
                        end
                        event_index_r <= event_index_r + 11'd1;
                        state_r <= ST_WAIT;
                    end
                    else state_r <= ST_SEND;
                ST_SEND:
                    if (deliver)
                    begin
                        on_r <= '0;
                        off_r <= '0;
                        sample_index_r <= sample_index_r + 21'd1;
                        if (event_index_r >= song_end && sample_index_r >= song_samples)
                        begin
                            song_done <= 1'b1;
                            state_r <= ST_FINISHED;
                        end
                        else state_r <= ST_WAIT;
                    end
                ST_FINISHED:
                    if (deliver)
                    begin
                        on_r <= '0;
                        off_r <= '0;
                    end
                ST_STOP:
                    if (deliver)
                    begin
                        on_r <= '0;
                        off_r <= '0;
                        state_r <= ST_BYPASS;
                    end
                default: state_r <= ST_BYPASS;
            endcase
        end
    end
endmodule
