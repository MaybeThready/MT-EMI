/**
 * 1024点SQ1.15完整窗口 -> WAVE_COLUMNS个纵向min/max区间，连接相邻列。
 * 全部在clk_sys/rst_sys_n域；不复制PCM，只读lcd_pcm_capture的已锁定窗口。
 * start_valid/start_ready接受window_seq；最后PCM结果使用后脉冲window_release。
 * build_enable由场景调度器提供，只有无任务读列缓存时才允许启动。
 * busy时禁止外部读列；单份2*WAVE_COLUMNS深16位SDP缓存复用到下一次构建。
 * column_rd_en/addr为同步读，一拍结果；地址2*j/2*j+1分别为y_min/y_max。
 * wave_done为完成脉冲；wave_valid表示缓存完整可读，重建时清0。
 * wave_seq/wave_peak只在整份缓存完成后更新，peak为无符号原码0..32768。
 * 绘图采样放大4倍并在满幅处削波，峰值数值仍为未放大的原始PCM。
 * 使用16位偏置码乘编译期常数、舍入右移16；无变量除法或饱和回绕。
 */
module lcd_waveform_builder
#(
    parameter WAVE_COLUMNS = 544, // 1..1024列；主图默认544，可配800。
    parameter GRAPH_Y_MIN = 96,   // 屏幕像素整数，0..478。
    parameter GRAPH_Y_MAX = 303,  // >MIN且<=479；不是Q格式。
    parameter EXTERNAL_COLUMNS = 0 // 1: caller provides shared column SDP.
)(
    input clk_sys,
    input rst_n,
    input build_enable,
    input start_valid,
    output start_ready,
    input [31:0] window_seq,
    output pcm_rd_en,
    output [9:0] pcm_rd_addr,
    input signed [15:0] pcm_rd_data,
    output window_release,
    output busy,
    output wave_done,
    output wave_valid,
    output [31:0] wave_seq,
    output [15:0] wave_peak,
    input column_rd_en,
    input [10:0] column_rd_addr,
    output [15:0] column_rd_data,
    // External-cache write transaction at clk_sys rising edge: address2*j is
    // y_min,2*j+1 is y_max (low9=y). EXTERNAL_COLUMNS=1 removes private RAM;
    // caller must exclude readers until wave_done and retain data for rendering.
    output column_wr_en,
    output [10:0] column_wr_addr,
    output [15:0] column_wr_data,
    output protocol_error,
    output configuration_error
);
    localparam [2:0] IDLE = 3'd0, READ_SAMPLE = 3'd1, MAP_SAMPLE = 3'd2,
        ACCUMULATE = 3'd3, WRITE_MIN = 3'd4, WRITE_MAX = 3'd5, FINISH = 3'd6;
    localparam STORAGE_COLUMNS = (WAVE_COLUMNS >= 1 && WAVE_COLUMNS <= 1024) ? WAVE_COLUMNS : 1;
    localparam [10:0] COLUMN_STEP = WAVE_COLUMNS;
    localparam [8:0] Y_SPAN = GRAPH_Y_MAX - GRAPH_Y_MIN;
    localparam [8:0] Y_BOTTOM = GRAPH_Y_MAX;
    wire [2:0] state;
    reg [2:0] next_state;
    reg [9:0] sample_index_r, column_index_r, phase_r;
    reg first_in_column_r;
    reg [8:0] sample_y_r, previous_y_r, minimum_r, maximum_r;
    reg [15:0] sample_magnitude_r, working_peak_r, wave_peak_r;
    reg [31:0] working_seq_r, wave_seq_r;
    reg window_release_r, wave_done_r, wave_valid_r, protocol_error_r;
    wire start_fire = start_valid && start_ready;
    // Scale only the plotted sample; keep the reported peak in raw PCM units.
    wire signed [15:0] display_pcm = (pcm_rd_data > 16'sd8191) ? 16'sh7fff :
        (pcm_rd_data < -16'sd8192) ? 16'sh8000 : {pcm_rd_data[13:0],2'b00};
    wire [15:0] biased_pcm = {~display_pcm[15], display_pcm[14:0]};
    wire [24:0] scaled_pcm = biased_pcm * Y_SPAN;
    wire [24:0] rounded_pcm = scaled_pcm + 25'd32768;
    wire [10:0] phase_sum = {1'b0, phase_r} + COLUMN_STEP;
    wire last_sample = (sample_index_r == 10'd1023);
    wire last_column = (column_index_r == WAVE_COLUMNS - 1);
    wire cache_write = (state == WRITE_MIN) || (state == WRITE_MAX);
    wire [10:0] cache_wr_addr = {column_index_r, (state == WRITE_MAX)};
    wire [15:0] cache_wr_data = {7'd0, (state == WRITE_MIN) ? minimum_r : maximum_r};

    assign configuration_error = (WAVE_COLUMNS < 1) || (WAVE_COLUMNS > 1024) ||
        (GRAPH_Y_MIN < 0) || (GRAPH_Y_MIN >= GRAPH_Y_MAX) || (GRAPH_Y_MAX > 479);
    assign busy = (state != IDLE);
    assign start_ready = rst_n && build_enable && !busy && !configuration_error;
    assign pcm_rd_en = (state == READ_SAMPLE);
    assign pcm_rd_addr = sample_index_r;
    assign window_release = window_release_r;
    assign wave_done = wave_done_r;
    assign wave_valid = wave_valid_r;
    assign wave_seq = wave_seq_r;
    assign wave_peak = wave_peak_r;
    assign protocol_error = protocol_error_r;
    assign column_wr_en = cache_write;
    assign column_wr_addr = cache_wr_addr;
    assign column_wr_data = cache_wr_data;

    fsm #(.W(3), .INITIAL_STATE(IDLE)) fsm_u (
        .clk(clk_sys), .rst_n(rst_n), .stn(next_state), .stc(state)
    );

    always @(*)
    begin
        next_state = state;
        case (state)
            IDLE: if (start_fire) next_state = READ_SAMPLE;
            READ_SAMPLE: next_state = MAP_SAMPLE;
            MAP_SAMPLE: next_state = ACCUMULATE;
            ACCUMULATE: next_state = phase_sum[10] ? WRITE_MIN : READ_SAMPLE;
            WRITE_MIN: next_state = WRITE_MAX;
            WRITE_MAX: next_state = last_column ? FINISH : READ_SAMPLE;
            FINISH: next_state = IDLE;
            default: next_state = IDLE;
        endcase
    end

    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            sample_index_r <= 10'd0;
            column_index_r <= 10'd0;
            phase_r <= 10'd0;
            first_in_column_r <= 1'b1;
            sample_y_r <= 9'd0;
            previous_y_r <= 9'd0;
            minimum_r <= 9'd0;
            maximum_r <= 9'd0;
            sample_magnitude_r <= 16'd0;
            working_peak_r <= 16'd0;
            wave_peak_r <= 16'd0;
            working_seq_r <= 32'd0;
            wave_seq_r <= 32'd0;
            window_release_r <= 1'b0;
            wave_done_r <= 1'b0;
            wave_valid_r <= 1'b0;
            protocol_error_r <= 1'b0;
        end
        else
        begin
            window_release_r <= 1'b0;
            wave_done_r <= 1'b0;
            if (column_rd_en && (busy || !wave_valid_r || column_rd_addr >= 2 * WAVE_COLUMNS))
                protocol_error_r <= 1'b1;
            case (state)
                IDLE:
                    if (start_fire)
                    begin
                        sample_index_r <= 10'd0;
                        column_index_r <= 10'd0;
                        phase_r <= 10'd0;
                        first_in_column_r <= 1'b1;
                        working_peak_r <= 16'd0;
                        working_seq_r <= window_seq;
                        wave_valid_r <= 1'b0;
                    end
                MAP_SAMPLE:
                begin
                    sample_y_r <= Y_BOTTOM - rounded_pcm[24:16];
                    sample_magnitude_r <= pcm_rd_data[15] ? (~pcm_rd_data + 16'd1) : pcm_rd_data;
                end
                ACCUMULATE:
                begin
                    if (first_in_column_r)
                    begin
                        minimum_r <= (column_index_r != 10'd0 && previous_y_r < sample_y_r) ? previous_y_r : sample_y_r;
                        maximum_r <= (column_index_r != 10'd0 && previous_y_r > sample_y_r) ? previous_y_r : sample_y_r;
                    end
                    else
                    begin
                        if (sample_y_r < minimum_r) minimum_r <= sample_y_r;
                        if (sample_y_r > maximum_r) maximum_r <= sample_y_r;
                    end
                    if (sample_magnitude_r > working_peak_r) working_peak_r <= sample_magnitude_r;
                    previous_y_r <= sample_y_r;
                    phase_r <= phase_sum[9:0];
                    first_in_column_r <= 1'b0;
                    sample_index_r <= sample_index_r + 10'd1;
                    if (last_sample) window_release_r <= 1'b1;
                end
                WRITE_MAX:
                begin
                    if (!last_column) column_index_r <= column_index_r + 10'd1;
                    first_in_column_r <= 1'b1;
                end
                FINISH:
                begin
                    wave_valid_r <= 1'b1;
                    wave_done_r <= 1'b1;
                    wave_seq_r <= working_seq_r;
                    wave_peak_r <= working_peak_r;
                end
                default:
                begin
                    // READ_SAMPLE/WRITE_MIN only issue a RAM port operation.
                end
            endcase
        end
    end

    generate
        if (EXTERNAL_COLUMNS == 0)
        begin : internal_columns
            lcd_sdp_ram #(.DATA_WIDTH(16), .DEPTH(2 * STORAGE_COLUMNS), .ADDR_WIDTH(11)) lcd_sdp_ram_u (
                .clk(clk_sys), .rst_n(rst_n), .wr_en(cache_write),
                .wr_addr(cache_wr_addr), .wr_data(cache_wr_data),
                .rd_en(column_rd_en && !busy && wave_valid_r && column_rd_addr < 2 * WAVE_COLUMNS),
                .rd_addr(column_rd_addr), .rd_data(column_rd_data)
            );
        end
        else
        begin : external_columns
            assign column_rd_data = 16'd0; // No internal RAM or read port.
        end
    endgenerate
endmodule
