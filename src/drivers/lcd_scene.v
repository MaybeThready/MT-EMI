/**
 * Double-buffered characters/columns, NOT a full-screen pixel framebuffer.
 * All state uses clk_sys/rst_sys_n. Coordinates/addresses are unsigned, no Q.
 * word_valid && word_ready writes BACK bank. Hold payload under backpressure.
 * kind=0: cell address row*ceil(H_ACTIVE/8)+col, cell size 8x16;
 *   data[6:0] ASCII, [10:7] foreground, [14:11] background, [15] opaque.
 * kind=1: column address x; [8:0] y_min, [17:9] y_max (inclusive),
 *   [21:18] colour, [22] enabled; [31:23] zero. Supports wave ranges/bars.
 * Invalid words are consumed without writing and latch address_error.
 * After all words hold present_valid until frame-boundary present_ready.
 * Pending present blocks writes. New back is cleared before ready returns;
 * sparse rebuilding is supported, no implicit copy of the previous scene.
 * Four-clock scan pipeline: address register, SDP read, glyph, composition.
 * H_ACTIVE 1..1024, V_ACTIVE 1..512. The driver validates configuration.
 */
module lcd_scene
#(
    parameter H_ACTIVE = 800,
    parameter V_ACTIVE = 480
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
    input frame_boundary,
    output frame_active,
    output address_error,
    input scan_active,
    input [9:0] scan_x,
    input [8:0] scan_y,
    output [3:0] pixel_index
);
    localparam CHAR_COLS = (H_ACTIVE + 7) / 8;
    localparam CHAR_COUNT = CHAR_COLS * ((V_ACTIVE + 15) / 16);
    localparam CLEAR_COUNT = (CHAR_COUNT > H_ACTIVE) ? CHAR_COUNT : H_ACTIVE;
    localparam STATE_CLEAR = 2'd0;
    localparam STATE_WRITE = 2'd1;
    localparam STATE_PRESENT = 2'd2;
    wire [1:0] current_state;
    reg [1:0] next_state;
    reg [12:0] clear_addr_r;
    reg front_bank_r, front_valid_r, address_error_r;
    wire accept, commit, valid_word, clearing;
    wire [11:0] write_addr;
    reg [11:0] char_read_addr_r;
    reg read_active_r;
    reg [9:0] read_x_r;
    reg [8:0] read_y_r;
    wire [15:0] char_data [1:0];
    wire [31:0] graph_data [1:0];
    wire [15:0] selected_char;
    wire [31:0] selected_graph;
    wire [7:0] glyph_row;
    reg bank_s0;
    reg [1:0] visible_r;
    reg [9:0] x_s0, x_s1;
    reg [8:0] y_s0, y_s1;
    reg [15:0] char_s1;
    reg [31:0] graph_s1;
    reg [3:0] composed, pixel_index_r;
    genvar bank_index;

    assign clearing = (current_state == STATE_CLEAR);
    assign word_ready = rst_n && (current_state == STATE_WRITE) && !present_valid;
    assign present_ready = rst_n && frame_boundary && !clearing;
    assign accept = word_valid && word_ready;
    assign commit = present_valid && present_ready;
    assign valid_word = word_kind ?
        ((word_addr < H_ACTIVE) && (word_data[31:23] == 9'd0) &&
         (!word_data[22] || ((word_data[8:0] <= word_data[17:9]) && (word_data[17:9] < V_ACTIVE)))) :
        ((word_addr < CHAR_COUNT) && (word_data[31:16] == 16'd0));
    assign write_addr = clearing ? clear_addr_r[11:0] : word_addr;
    assign selected_char = bank_s0 ? char_data[1] : char_data[0];
    assign selected_graph = bank_s0 ? graph_data[1] : graph_data[0];
    assign frame_active = front_valid_r;
    assign address_error = address_error_r;
    assign pixel_index = pixel_index_r;

    // A row is only 5 bits. Explicit constant shifts/adds avoid the unregistered
    // MULT12X12 inferred from row*CHAR_COLS in the failing implementation.
    function [11:0] character_row_offset;
        input [4:0] row;
        integer coefficient_bit;
        reg [11:0] offset;
        begin
            offset = 12'd0;
            for (coefficient_bit = 0; coefficient_bit < 8; coefficient_bit = coefficient_bit + 1)
            begin
                if (((CHAR_COLS >> coefficient_bit) & 1) != 0)
                    offset = offset + ({7'd0, row} << coefficient_bit);
            end
            character_row_offset = offset;
        end
    endfunction

    // Register the complete memory request. Ownership switches at the actual
    // memory edge; do not tag requests early or clear a bank still being read.
    always @(posedge clk or negedge rst_n)
    begin
        if (!rst_n)
        begin
            char_read_addr_r <= 12'd0;
            read_active_r <= 1'b0;
            read_x_r <= 10'd0;
            read_y_r <= 9'd0;
        end
        else
        begin
            char_read_addr_r <= character_row_offset(scan_y[8:4]) + {5'd0, scan_x[9:3]};
            read_active_r <= scan_active;
            read_x_r <= scan_x;
            read_y_r <= scan_y;
        end
    end

    fsm #(.W(2), .INITIAL_STATE(STATE_CLEAR)) fsm_u (
        .clk(clk), .rst_n(rst_n), .stn(next_state), .stc(current_state)
    );
    generate
        for (bank_index = 0; bank_index < 2; bank_index = bank_index + 1)
        begin : scene_banks
            lcd_sdp_ram #(.DATA_WIDTH(16), .DEPTH(CHAR_COUNT), .ADDR_WIDTH(12)) char_ram_u (
                .clk(clk), .rst_n(rst_n),
                .wr_en((front_bank_r != bank_index) && ((clearing && (clear_addr_r < CHAR_COUNT)) ||
                    (accept && valid_word && !word_kind))),
                .wr_addr(write_addr), .wr_data(clearing ? 16'd0 : word_data[15:0]),
                .rd_en(read_active_r && front_valid_r && (front_bank_r == bank_index)),
                .rd_addr(char_read_addr_r), .rd_data(char_data[bank_index])
            );
            lcd_sdp_ram #(.DATA_WIDTH(32), .DEPTH(H_ACTIVE), .ADDR_WIDTH(12)) graph_ram_u (
                .clk(clk), .rst_n(rst_n),
                .wr_en((front_bank_r != bank_index) && ((clearing && (clear_addr_r < H_ACTIVE)) ||
                    (accept && valid_word && word_kind))),
                .wr_addr(write_addr), .wr_data(clearing ? 32'd0 : word_data),
                .rd_en(read_active_r && front_valid_r && (front_bank_r == bank_index)),
                .rd_addr({2'b00, read_x_r}), .rd_data(graph_data[bank_index])
            );
        end
    endgenerate
    lcd_font_rom lcd_font_rom_u (
        .clk(clk), .rst_n(rst_n), .ascii_code(selected_char[6:0]),
        .glyph_y(y_s0[3:0]), .glyph_row(glyph_row)
    );

    always @(*)
    begin
        next_state = current_state;
        case (current_state)
            STATE_CLEAR:
                if (clear_addr_r == CLEAR_COUNT - 1) next_state = STATE_WRITE;
            STATE_WRITE:
                if (commit) next_state = STATE_CLEAR;
                else if (present_valid) next_state = STATE_PRESENT;
            STATE_PRESENT:
                if (commit) next_state = STATE_CLEAR;
            default: next_state = STATE_CLEAR;
        endcase
    end

    always @(posedge clk or negedge rst_n)
    begin
        if (!rst_n)
        begin
            clear_addr_r <= 13'd0;
            front_bank_r <= 1'b0;
            front_valid_r <= 1'b0;
            address_error_r <= 1'b0;
        end
        else
        begin
            if (clearing)
            begin
                if (clear_addr_r == CLEAR_COUNT - 1) clear_addr_r <= 13'd0;
                else clear_addr_r <= clear_addr_r + 13'd1;
            end
            if (commit)
            begin
                front_bank_r <= !front_bank_r;
                front_valid_r <= 1'b1;
            end
            if (accept && !valid_word) address_error_r <= 1'b1;
        end
    end

    // Carry each pixel's coordinates, visibility and bank through the pipeline.
    always @(posedge clk or negedge rst_n)
    begin
        if (!rst_n)
        begin
            bank_s0 <= 1'b0;
            visible_r <= 2'b00;
            x_s0 <= 10'd0;
            x_s1 <= 10'd0;
            y_s0 <= 9'd0;
            y_s1 <= 9'd0;
            char_s1 <= 16'd0;
            graph_s1 <= 32'd0;
            pixel_index_r <= 4'd0;
        end
        else
        begin
            bank_s0 <= front_bank_r;
            visible_r <= {visible_r[0], read_active_r && front_valid_r};
            x_s0 <= read_x_r;
            x_s1 <= x_s0;
            y_s0 <= read_y_r;
            y_s1 <= y_s0;
            char_s1 <= selected_char;
            graph_s1 <= selected_graph;
            pixel_index_r <= visible_r[1] ? composed : 4'd0;
        end
    end

    always @(*)
    begin
        composed = 4'd8;
        if ((x_s1[5:0] == 6'd0) || (y_s1[5:0] == 6'd0)) composed = 4'd10;
        if (graph_s1[22] && (y_s1 >= graph_s1[8:0]) && (y_s1 <= graph_s1[17:9]))
            composed = graph_s1[21:18];
        if (char_s1[15]) composed = char_s1[14:11];
        if (glyph_row[7-x_s1[2:0]]) composed = char_s1[10:7];
    end
endmodule
