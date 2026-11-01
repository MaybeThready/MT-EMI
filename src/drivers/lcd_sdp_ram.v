/**
 * Compact scene SDP storage: real GW5A SDPB in simulation and synthesis.
 * DATA_WIDTH: 16 or 32 unsigned bits; DEPTH: words; ADDR_WIDTH >= clog2(DEPTH).
 * Both ports use clk_sys. Read result appears after the enabled rising edge.
 * Reset affects output/select only. Caller clears memory before displaying.
 * Broadcast low address bits; select transfers through CEA/CEB, not address gates.
 */
module lcd_sdp_ram
#(
    parameter DATA_WIDTH = 16,
    parameter DEPTH = 3000,
    parameter ADDR_WIDTH = 12
)(
    input clk,
    input rst_n,
    input wr_en,
    input [ADDR_WIDTH-1:0] wr_addr,
    input [DATA_WIDTH-1:0] wr_data,
    input rd_en,
    input [ADDR_WIDTH-1:0] rd_addr,
    output [DATA_WIDTH-1:0] rd_data
);
    localparam WORD_BITS = (DATA_WIDTH == 32) ? 9 : 10;
    localparam BLOCK_COUNT = (DEPTH + (1 << WORD_BITS) - 1) >> WORD_BITS;
    localparam SELECT_WIDTH = (BLOCK_COUNT <= 1) ? 1 : $clog2(BLOCK_COUNT);
    wire [31:0] block_data [BLOCK_COUNT-1:0];
    wire [31:0] wr_address;
    wire [31:0] rd_address;
    wire [13:0] native_wr_address;
    wire [13:0] native_rd_address;
    reg [SELECT_WIDTH-1:0] rd_block_r;
    genvar block_index;

    assign wr_address = wr_addr;
    assign rd_address = rd_addr;
    // GW5A 16/32-bit SDPB uses low ADA bits as byte write enables.
    assign native_wr_address = (wr_address << (14 - WORD_BITS)) |
        ((DATA_WIDTH == 32) ? 14'h000f : 14'h0003);
    assign native_rd_address = rd_address << (14 - WORD_BITS);
    assign rd_data = block_data[rd_block_r][DATA_WIDTH-1:0];

    always @(posedge clk or negedge rst_n)
    begin
        if (!rst_n) rd_block_r <= {SELECT_WIDTH{1'b0}};
        else if (rd_en && (rd_address < DEPTH)) rd_block_r <= rd_address >> WORD_BITS;
    end

    generate
        for (block_index = 0; block_index < BLOCK_COUNT; block_index = block_index + 1)
        begin : ram_blocks
            SDPB #(
                .READ_MODE(1'b0), .BIT_WIDTH_0(DATA_WIDTH), .BIT_WIDTH_1(DATA_WIDTH),
                .BLK_SEL_0(3'b000), .BLK_SEL_1(3'b000), .RESET_MODE("ASYNC")
            ) sdpb_u (
                .CLKA(clk), .CLKB(clk),
                .CEA(rst_n && wr_en && (wr_address < DEPTH) && ((wr_address >> WORD_BITS) == block_index)),
                .CEB(rst_n && rd_en && (rd_address < DEPTH) && ((rd_address >> WORD_BITS) == block_index)),
                .OCE(1'b1), .RESET(!rst_n), .BLKSELA(3'b000), .BLKSELB(3'b000),
                .ADA(native_wr_address), .ADB(native_rd_address),
                .DI({{(32-DATA_WIDTH){1'b0}}, wr_data}), .DO(block_data[block_index])
            );
        end
    endgenerate
endmodule
