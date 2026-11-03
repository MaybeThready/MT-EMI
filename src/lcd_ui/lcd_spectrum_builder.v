/**
 * 1024点Hann频谱映射为线性频率轴的相对幅度纵向条形。
 * 统一使用clk_sys/rst_sys_n；PCM窗口握手、同步读取与释放遵循lcd_pcm_capture协议。
 * 采样率由编译期有理数NUM/DEN配置，默认98245614/2048Hz来自现有PLL和采样节拍，不改变时钟。
 * FFT仅输出0..floor(FREQ_VIEW_MAX_HZ*1024/Fs)谱线；用加减相位累加器扩展到显示列。
 * 多个谱线落入同一列时取最大幅度，无变量除法；每列写两个16位字，上/下端点使用低9位y坐标。
 * 调用方维护波形/频谱共享列缓存，busy期间禁止读缓存；本模块不复制列RAM，也不为每列实例化FFT或DSP。
 * 所有列写完后才一并提交序号、峰值、标志与spectrum_valid；绘图幅值放大16倍并在满幅处削波，原始峰值和FFT标志不变。
 */
module lcd_spectrum_builder
#(
    parameter WAVE_COLUMNS = 544, // Integer1..1024, matches shared cache depth.
    parameter GRAPH_Y_MIN = 96,
    parameter GRAPH_Y_MAX = 303,  // Pixel integers,0<=MIN<MAX<=479.
    parameter SAMPLE_RATE_NUM = 98245614, // Hz numerator,positive integer.
    parameter SAMPLE_RATE_DEN = 2048,     // Hz denominator,positive integer.
    parameter FREQ_VIEW_MAX_HZ = 2000     // >0 and <=Fs/2; limits FFT output bins and display range.
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
    output spectrum_done,
    output spectrum_valid,
    output [31:0] spectrum_seq,
    output [15:0] spectrum_peak, // Raw,unwindowed PCM abs max0..32768.
    output spectrum_clipped,    // A frequency amplitude exceeded1FS.
    output fft_overflow,        // Numerical butterfly saturation, separate flag.
    output column_wr_en,
    output [10:0] column_wr_addr,
    output [15:0] column_wr_data,
    output configuration_error
);
    localparam SAFE_NUM = (SAMPLE_RATE_NUM > 0) ? SAMPLE_RATE_NUM : 1;
    localparam [63:0] RAW_MAX_BIN = (64'd1024 * SAMPLE_RATE_DEN * FREQ_VIEW_MAX_HZ) / SAFE_NUM;
    localparam MAX_BIN = (RAW_MAX_BIN <= 512) ? RAW_MAX_BIN : 0;
    localparam BIN_COUNT = MAX_BIN + 1;
    localparam [8:0] Y_SPAN = GRAPH_Y_MAX - GRAPH_Y_MIN;
    localparam [8:0] Y_BOTTOM = GRAPH_Y_MAX;
    localparam [2:0] IDLE=3'd0, WAIT_BIN=3'd1, TEST_PHASE=3'd2, MAP_HEIGHT=3'd3,
        WRITE_MIN=3'd4, WRITE_MAX=3'd5, NEXT_BIN=3'd6, FINISH=3'd7;
    wire [2:0] state;
    reg [2:0] next_state;
    reg [10:0] phase_r, columns_written_r;
    reg [9:0] processed_bin_r;
    reg [15:0] group_max_r;
    reg [8:0] bar_top_r;
    reg wrote_column_r, done_r, valid_r;
    reg [31:0] seq_r;
    reg [15:0] peak_r;
    reg clipped_r, overflow_r;
    wire core_start_ready, core_out_valid, core_configuration_error;
    wire [9:0] core_index;
    wire [15:0] core_magnitude, core_peak;
    wire [31:0] core_seq;
    wire core_clipped, core_overflow;
    wire start_fire = start_valid && start_ready;
    // Amplify the graph only. FFT clipping flags retain their original meaning.
    wire [15:0] display_magnitude = (group_max_r >= 16'd2048) ? 16'd32768 :
        {group_max_r[11:0],4'b0000};
    wire [24:0] height_product = display_magnitude * Y_SPAN + 25'd16384;

    assign configuration_error = (WAVE_COLUMNS < 1) || (WAVE_COLUMNS > 1024) ||
        (GRAPH_Y_MIN < 0) || (GRAPH_Y_MIN >= GRAPH_Y_MAX) || (GRAPH_Y_MAX > 479) ||
        (SAMPLE_RATE_NUM <= 0) || (SAMPLE_RATE_DEN <= 0) || (FREQ_VIEW_MAX_HZ <= 0) ||
        (64'd2 * SAMPLE_RATE_DEN * FREQ_VIEW_MAX_HZ > SAFE_NUM) || core_configuration_error;
    assign start_ready = rst_n && (state==IDLE) && build_enable && !configuration_error && core_start_ready;
    assign busy = (state!=IDLE);
    assign spectrum_done = done_r;
    assign spectrum_valid = valid_r;
    assign spectrum_seq = seq_r;
    assign spectrum_peak = peak_r;
    assign spectrum_clipped = clipped_r;
    assign fft_overflow = overflow_r;
    assign column_wr_en = (state==WRITE_MIN) || (state==WRITE_MAX);
    assign column_wr_addr = {columns_written_r[9:0],(state==WRITE_MAX)};
    assign column_wr_data = {7'd0,(state==WRITE_MIN) ? bar_top_r : Y_BOTTOM};

    fsm #(.W(3), .INITIAL_STATE(IDLE)) fsm_u (
        .clk(clk_sys), .rst_n(rst_n), .stn(next_state), .stc(state)
    );
    lcd_fft1024 #(.MAX_OUTPUT_BIN(MAX_BIN)) lcd_fft1024_u (
        .clk_sys(clk_sys), .rst_n(rst_n),
        .start_valid(start_valid && build_enable && state==IDLE && !configuration_error),
        .start_ready(core_start_ready), .window_seq(window_seq),
        .pcm_rd_en(pcm_rd_en), .pcm_rd_addr(pcm_rd_addr), .pcm_rd_data(pcm_rd_data),
        .window_release(window_release), .busy(), .done(),
        .out_valid(core_out_valid), .out_ready(state==WAIT_BIN), .out_index(core_index),
        .out_real(), .out_imag(), .out_magnitude(core_magnitude), .out_seq(core_seq),
        .pcm_peak(core_peak), .fft_overflow(core_overflow), .amplitude_clipped(core_clipped),
        .configuration_error(core_configuration_error)
    );
    always @(*)
    begin
        next_state=state;
        case (state)
            IDLE: if (start_fire) next_state=WAIT_BIN;
            WAIT_BIN: if (core_out_valid) next_state=TEST_PHASE;
            TEST_PHASE: next_state=(phase_r>=BIN_COUNT) ? MAP_HEIGHT : NEXT_BIN;
            MAP_HEIGHT: next_state=WRITE_MIN;
            WRITE_MIN: next_state=WRITE_MAX;
            WRITE_MAX: next_state=TEST_PHASE;
            NEXT_BIN: next_state=(processed_bin_r==MAX_BIN) ? FINISH : WAIT_BIN;
            FINISH: next_state=IDLE;
            default: next_state=IDLE;
        endcase
    end
    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            phase_r<=11'd0; columns_written_r<=11'd0; processed_bin_r<=10'd0;
            group_max_r<=16'd0; bar_top_r<=9'd0; wrote_column_r<=1'b0;
            done_r<=1'b0; valid_r<=1'b0; seq_r<=32'd0; peak_r<=16'd0;
            clipped_r<=1'b0; overflow_r<=1'b0;
        end
        else
        begin
            done_r<=1'b0;
            case (state)
                IDLE:
                    if (start_fire)
                    begin
                        phase_r<=11'd0; columns_written_r<=11'd0; group_max_r<=16'd0;
                        wrote_column_r<=1'b0; valid_r<=1'b0;
                    end
                WAIT_BIN:
                    if (core_out_valid)
                    begin
                        phase_r<=phase_r+WAVE_COLUMNS;
                        if (core_magnitude>group_max_r) group_max_r<=core_magnitude;
                        processed_bin_r<=core_index;
                        wrote_column_r<=1'b0;
                    end
                MAP_HEIGHT: bar_top_r<=Y_BOTTOM-height_product[23:15];
                WRITE_MAX:
                begin
                    columns_written_r<=columns_written_r+11'd1;
                    phase_r<=phase_r-BIN_COUNT;
                    wrote_column_r<=1'b1;
                end
                NEXT_BIN: if (wrote_column_r) group_max_r<=16'd0;
                FINISH:
                begin
                    valid_r<=1'b1; done_r<=1'b1; seq_r<=core_seq; peak_r<=core_peak;
                    clipped_r<=core_clipped; overflow_r<=core_overflow;
                end
                default:
                begin
                    // Read/FFT and column-write scheduling retain the model.
                end
            endcase
        end
    end
endmodule
