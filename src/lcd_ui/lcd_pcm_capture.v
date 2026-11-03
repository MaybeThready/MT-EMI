/**
 * 连续播放PCM双窗口：两个1024x16 SDP银行，无逐采样FIFO/FF数组。
 * clk_sys/rst_n接系统时钟/rst_sys_n；audio_in为原码SQ1.15。
 * in_valid && in_ready接受一个样本；rst_n释放后in_ready恒1，绘制不反压I2S。
 * window_valid && window_ready锁定完整1024点窗口；窗口序号等待时保持。
 * 锁内rd_en/rd_addr发起同步读，结果在该上升沿之后出现并保持。
 * window_release在消费者已取走最后读结果后脉冲一拍。禁止无锁读/释放。
 * 完成新窗口而另一银行未释放时丢弃刚完成的整窗；不覆盖待接收/读锁窗口。
 * 同沿释放旧锁与完成新窗可立即换银行。序号和丢窗计数按32位自然回绕。
 */
module lcd_pcm_capture
#(
    parameter [31:0] INITIAL_SEQ = 32'd0 // 首窗编号，仅影响复位初值。
)(
    input clk_sys,
    input rst_n,
    input signed [15:0] audio_in,
    input in_valid,
    output in_ready,
    output window_valid,
    input window_ready,
    output [31:0] window_seq,
    input window_release,
    input rd_en,
    input [9:0] rd_addr,
    output signed [15:0] rd_data,
    output [31:0] dropped_windows,
    output protocol_error
);
    localparam [1:0] FREE = 2'd0, READY = 2'd1, READ_LOCK = 2'd2;
    wire [1:0] state;
    reg [1:0] next_state;
    reg capture_bank_r;
    reg rd_bank_r;
    reg [9:0] wr_addr_r;
    reg [31:0] next_seq_r, window_seq_r, dropped_windows_r;
    reg protocol_error_r;
    wire input_fire = in_valid && in_ready;
    wire window_end = input_fire && (wr_addr_r == 10'd1023);
    wire bank_free = (state == FREE) || ((state == READ_LOCK) && window_release);
    wire publish_window = window_end && bank_free;
    wire read_fire = rd_en && (state == READ_LOCK);
    wire [15:0] bank_data [0:1];
    genvar bank;

    assign in_ready = rst_n;
    assign window_valid = (state == READY);
    assign window_seq = window_seq_r;
    assign rd_data = bank_data[rd_bank_r];
    assign dropped_windows = dropped_windows_r;
    assign protocol_error = protocol_error_r;

    fsm #(.W(2), .INITIAL_STATE(FREE)) fsm_u (
        .clk(clk_sys), .rst_n(rst_n), .stn(next_state), .stc(state)
    );

    always @(*)
    begin
        next_state = state;
        case (state)
            FREE: if (window_end) next_state = READY;
            READY: if (window_ready) next_state = READ_LOCK;
            READ_LOCK: if (window_release) next_state = window_end ? READY : FREE;
            default: next_state = FREE;
        endcase
    end

    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            capture_bank_r <= 1'b0;
            rd_bank_r <= 1'b0;
            wr_addr_r <= 10'd0;
            next_seq_r <= INITIAL_SEQ;
            window_seq_r <= 32'd0;
            dropped_windows_r <= 32'd0;
            protocol_error_r <= 1'b0;
        end
        else
        begin
            if (input_fire) wr_addr_r <= wr_addr_r + 10'd1;
            if (window_end)
            begin
                next_seq_r <= next_seq_r + 32'd1;
                if (!bank_free) dropped_windows_r <= dropped_windows_r + 32'd1;
            end
            if (publish_window)
            begin
                capture_bank_r <= ~capture_bank_r;
                window_seq_r <= next_seq_r;
            end
            // Record read-bank with the request: a simultaneous capture-bank
            // swap must not change the mux for the just-returned RAM word.
            if (read_fire) rd_bank_r <= ~capture_bank_r;
            if ((rd_en || window_release) && state != READ_LOCK)
                protocol_error_r <= 1'b1;
        end
    end

    generate
        for (bank = 0; bank < 2; bank = bank + 1)
        begin : pcm_banks
            lcd_sdp_ram #(.DATA_WIDTH(16), .DEPTH(1024), .ADDR_WIDTH(10)) lcd_sdp_ram_u (
                .clk(clk_sys), .rst_n(rst_n),
                .wr_en(input_fire && (capture_bank_r == bank)),
                .wr_addr(wr_addr_r), .wr_data(audio_in),
                .rd_en(read_fire && (capture_bank_r != bank)),
                .rd_addr(rd_addr), .rd_data(bank_data[bank])
            );
        end
    endgenerate
endmodule
