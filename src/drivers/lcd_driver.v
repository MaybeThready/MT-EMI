/**
 * Native RGB666 scan with compact scene synthesis, no full-screen pixel RAM.
 * All logic uses clk_sys/rst_sys_n; lcd_clk is only an output to the panel.
 * Parameters: pixels/lines; PIXEL_DIV even >=2 system cycles per pixel.
 * Default raster unchanged: 800x480, totals 1192x533, /4, HS/VS high.
 * Scene write encoding/handshake is specified in lcd_scene.v.
 * Six stages align PCLK/DE with registered coordinates/address, SDP, glyph,
 * composition and palette. RGB updates
 * at falling PCLK, remains stable at rising sampling edge. Scan never waits.
 */
module lcd_driver
#(
    parameter PIXEL_DIV = 4,
    parameter H_ACTIVE = 800,
    parameter H_BACK = 182,
    parameter H_FRONT = 210,
    parameter V_ACTIVE = 480,
    parameter V_BACK = 8,
    parameter V_FRONT = 45
)(
    input clk,
    input rst_n,
    input word_valid,
    output word_ready,
    input word_kind,
    input [11:0] word_addr,
    input [31:0] word_data,
    input present_valid,
    output present_ready,
    output frame_start,
    output frame_active,
    output address_error,
    output configuration_error,
    output lcd_clk,
    output lcd_en,
    output [5:0] lcd_r,
    output [5:0] lcd_g,
    output [5:0] lcd_b,
    output lcd_bl,
    output lcd_hs_n,
    output lcd_vs_n
);
    localparam H_TOTAL = H_BACK + H_ACTIVE + H_FRONT;
    localparam V_TOTAL = V_BACK + V_ACTIVE + V_FRONT;
    localparam DIV_WIDTH = (PIXEL_DIV <= 2) ? 1 : $clog2(PIXEL_DIV);
    localparam SAFE_WIDTH = (H_ACTIVE >= 1 && H_ACTIVE <= 1024) ? H_ACTIVE : 1;
    localparam SAFE_HEIGHT = (V_ACTIVE >= 1 && V_ACTIVE <= 512) ? V_ACTIVE : 1;
    reg [DIV_WIDTH-1:0] phase_r;
    reg [15:0] h_count_r, v_count_r;
    reg [5:0] clock_pipe_r, active_pipe_r, frame_pipe_r;
    reg [1:0] memory_boundary_r;
    reg scan_active_r;
    reg [9:0] scan_x_r;
    reg [8:0] scan_y_r;
    reg [17:0] rgb_r;
    wire active_pixel, raster_wrap, scene_ready;
    wire [9:0] scan_x;
    wire [8:0] scan_y;
    wire [3:0] scene_index;
    wire [17:0] scene_rgb;

    assign configuration_error = (PIXEL_DIV < 2) || ((PIXEL_DIV % 2) != 0) ||
        (H_ACTIVE < 1) || (H_ACTIVE > 1024) || (V_ACTIVE < 1) || (V_ACTIVE > 512) ||
        (H_BACK < 0) || (H_FRONT < 0) || (V_BACK < 0) || (V_FRONT < 0) ||
        (H_TOTAL > 65535) || (V_TOTAL > 65535);
    assign active_pixel = !configuration_error && (h_count_r >= H_BACK) &&
        (h_count_r < H_BACK + H_ACTIVE) && (v_count_r >= V_BACK) && (v_count_r < V_BACK + V_ACTIVE);
    assign scan_x = active_pixel ? (h_count_r - H_BACK) : 10'd0;
    assign scan_y = active_pixel ? (v_count_r - V_BACK) : 9'd0;
    assign raster_wrap = !configuration_error && (phase_r == PIXEL_DIV - 1) &&
        (h_count_r == H_TOTAL - 1) && (v_count_r == V_TOTAL - 1);
    assign word_ready = scene_ready && !configuration_error;
    assign lcd_clk = clock_pipe_r[5];
    assign lcd_en = active_pipe_r[5];
    assign frame_start = frame_pipe_r[5];
    assign {lcd_r, lcd_g, lcd_b} = rgb_r;
    assign lcd_bl = rst_n && !configuration_error;
    assign lcd_hs_n = 1'b1;
    assign lcd_vs_n = 1'b1;

    lcd_scene #(.H_ACTIVE(SAFE_WIDTH), .V_ACTIVE(SAFE_HEIGHT)) lcd_scene_u (
        .clk(clk), .rst_n(rst_n), .word_valid(word_valid && !configuration_error), .word_ready(scene_ready),
        .word_kind(word_kind), .word_addr(word_addr), .word_data(word_data),
        .present_valid(present_valid && !configuration_error), .present_ready(present_ready),
        // Commit exactly with the last SDP read, not before pending coordinates.
        .frame_boundary(memory_boundary_r[1]), .frame_active(frame_active), .address_error(address_error),
        .scan_active(scan_active_r), .scan_x(scan_x_r), .scan_y(scan_y_r), .pixel_index(scene_index)
    );
    lcd_palette lcd_palette_u (.pixel_index(scene_index), .pixel_rgb(scene_rgb));

    always @(posedge clk or negedge rst_n)
    begin
        if (!rst_n)
        begin
            phase_r <= {DIV_WIDTH{1'b0}};
            h_count_r <= 16'd0;
            v_count_r <= 16'd0;
            clock_pipe_r <= 6'd0;
            active_pipe_r <= 6'd0;
            frame_pipe_r <= 6'd0;
            memory_boundary_r <= 2'd0;
            scan_active_r <= 1'b0;
            scan_x_r <= 10'd0;
            scan_y_r <= 9'd0;
            rgb_r <= 18'd0;
        end
        else
        begin
            // Cut raw scan comparisons/subtraction away from RAM address logic.
            scan_active_r <= active_pixel;
            scan_x_r <= scan_x;
            scan_y_r <= scan_y;
            memory_boundary_r <= {memory_boundary_r[0], raster_wrap};
            clock_pipe_r <= {clock_pipe_r[4:0], !configuration_error && (phase_r >= PIXEL_DIV / 2)};
            active_pipe_r <= {active_pipe_r[4:0], active_pixel};
            frame_pipe_r <= {frame_pipe_r[4:0], raster_wrap};
            rgb_r <= scene_rgb;
            if (phase_r == PIXEL_DIV - 1)
            begin
                phase_r <= {DIV_WIDTH{1'b0}};
                if (h_count_r == H_TOTAL - 1)
                begin
                    h_count_r <= 16'd0;
                    if (v_count_r == V_TOTAL - 1) v_count_r <= 16'd0;
                    else v_count_r <= v_count_r + 16'd1;
                end
                else h_count_r <= h_count_r + 16'd1;
            end
            else phase_r <= phase_r + {{(DIV_WIDTH-1){1'b0}}, 1'b1};
        end
    end
endmodule
