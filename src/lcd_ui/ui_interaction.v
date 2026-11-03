/**
 * 2026-11-02 S2和弦：快照[509]已确认模式、[510]子菜单、[511]候选。
 * 接受三个位并随latest/scene冻结；仅子菜单置位而page!=1时报协议错。
 * 候选可保留在其他页面，不参与活动事件OR；显示背压仍不影响PCM。
 * UI显示接收与冻结场景调度模块，快照宽度545位。
 * 接收完整UI状态，向drawers发布冻结场景；内部包含连续播放PCM采集和波形/频谱共享列缓存。
 * 文字绘制与LCD绘图字生成由后级drawers负责；clk_sys/rst_n与UI同域，复位接rst_sys_n，无跨时钟域传输。
 * display_in_*对接user_interface.display_out_*；旧场景等待或绘制期间仍可接受新快照。
 * scene_state、highlight_mask和default_mask保持到render_done；out_valid && out_ready接受一项绘制任务。
 * render_done可在任务接受同拍或后续单拍确认，输入ready不得由绘图引擎背压决定。
 * 提示计时器位宽为clog2(HIGHLIGHT_MS+1)，毫秒使能提前一计数预译码，保持原相位，不产生新时钟。
 * 活动提示持续HIGHLIGHT_MS毫秒，复位参数事件另有默认值提示；不提供键盘灯或held_keys接口。
 * 频谱采用1024点Hann窗与线性相对幅度；audio_in_*连接I2S实际播放镜像，包含欠载静音，不阻塞I2S。
 * 列缓存及场景元数据保持到render_done；新窗口仅在绘制任务之外构建，无需第二份列缓存。
 */
module ui_interaction
#(
    parameter CLK_SYS_HZ = 98245614, // System Hz; only prompt timing uses this.
    parameter HIGHLIGHT_MS = 800,   // Integer ms, legal1..65535.
    parameter WAVE_COLUMNS = 544,
    parameter GRAPH_Y_MIN = 96,
    parameter GRAPH_Y_MAX = 303,
    parameter SPECTRUM_SAMPLE_RATE_NUM = 98245614, // Actual Hz numerator.
    parameter SPECTRUM_SAMPLE_RATE_DEN = 2048,     // Actual Hz denominator.
    parameter SPECTRUM_MAX_HZ = 20000             // Display frequency range only.
)(
    input clk_sys,
    input rst_n,
    input [544:0] display_in_state,
    input display_in_valid,
    output display_in_ready,
    // NEW: I2S actual played PCM, SQ1.15. audio_in_ready=rst_n, independent
    // of UI valid, scene backpressure, cache availability and configuration.
    input signed [15:0] audio_in,
    input audio_in_valid,
    output audio_in_ready,
    output [544:0] scene_state,
    output [21:0] highlight_mask,
    output [21:0] default_mask,
    output out_valid,
    input out_ready,
    input render_done,
    // NEW: metadata for the same frozen column cache. Peak is unsigned PCM
    // magnitude 0..32768, not UQ0.16. Before the first complete build valid=0.
    output scene_wave_valid,
    output [31:0] scene_wave_seq,
    output [15:0] scene_output_peak,
    output scene_pcm_valid,
    // Spectrum metadata belongs to the same frozen cache. The two graph-valid
    // flags are mutually exclusive and must agree with scene_state[500]. A
    // view switch before matching data finishes produces WAITING, never a
    // waveform relabelled as a spectrum. Seq aliases the shared window tag.
    output scene_spectrum_valid,
    output [31:0] scene_spectrum_seq,
    output scene_spectrum_clipped, // Linear magnitude exceeded1FS.
    output scene_fft_overflow,     // Numerical FFT saturation, not audio clip.
    output [31:0] scene_dropped_windows,
    // NEW: synchronous one-cycle read, 2*j=top,2*j+1=bottom. Only read inside
    // an accepted scene with scene_wave_valid or scene_spectrum_valid;
    // waveform uses min/max, spectrum uses bar top/baseline, low9=y, high7=0.
    input column_rd_en,
    input [10:0] column_rd_addr,
    output [15:0] column_rd_data,
    output [31:0] dropped_windows, // Live whole-window drops, modulo2^32.
    output protocol_error,
    output configuration_error
);
    localparam IDLE = 2'd0, FREEZE_SCENE = 2'd1, SEND_SCENE = 2'd2, WAIT_RENDER = 2'd3;
    localparam MS_DIV = (CLK_SYS_HZ >= 1000) ? ((CLK_SYS_HZ + 500) / 1000) : 1;
    localparam MS_WIDTH = (MS_DIV <= 1) ? 1 : $clog2(MS_DIV);
    localparam TIMER_LIMIT = (HIGHLIGHT_MS>=1 && HIGHLIGHT_MS<=65535) ? HIGHLIGHT_MS : 1;
    localparam TIMER_WIDTH = (TIMER_LIMIT<=1) ? 1 : $clog2(TIMER_LIMIT+1);
    wire [1:0] state;
    reg [1:0] next_state;
    reg [MS_WIDTH-1:0] ms_count_r;
    wire ms_tick;
    generate
        if (MS_DIV<=1)
        begin : every_cycle_tick
            assign ms_tick=1'b1;
        end
        else
        begin : registered_ms_tick
            reg ms_tick_r;
            assign ms_tick=ms_tick_r;
            always @(posedge clk_sys or negedge rst_n)
            begin
                if (!rst_n) ms_tick_r<=1'b0;
                else ms_tick_r<=(ms_count_r==MS_DIV-2);
            end
        end
    endgenerate
    reg [544:0] latest_r, scene_r;
    reg have_state_r, dirty_r, protocol_error_r;
    reg [21:0] highlight_r, defaults_r, reset_latched_r;
    reg [21:0] pending_activity_r, pending_reset_r;
    reg [TIMER_WIDTH-1:0] remaining_r [0:21];
    reg wave_pending_r, scene_wave_valid_r;
    reg scene_pcm_valid_r, scene_spectrum_valid_r, scene_spectrum_clipped_r, scene_fft_overflow_r;
    reg cache_view_r, cache_valid_r;
    reg [31:0] scene_wave_seq_r, scene_dropped_windows_r;
    reg [15:0] scene_output_peak_r;
    wire pcm_window_valid, pcm_window_ready, pcm_release, pcm_rd_en;
    wire [31:0] pcm_window_seq;
    wire [9:0] pcm_rd_addr;
    wire signed [15:0] pcm_rd_data;
    wire pcm_protocol_error, wave_protocol_error, wave_configuration_error;
    wire waveform_busy, waveform_done, waveform_valid, waveform_ready;
    wire spectrum_busy, spectrum_done, spectrum_valid, spectrum_ready, spectrum_configuration_error;
    wire spectrum_clipped, spectrum_overflow;
    wire [31:0] waveform_seq, spectrum_seq;
    wire [15:0] waveform_peak, spectrum_peak;
    wire waveform_read, spectrum_read, waveform_release, spectrum_release;
    wire [9:0] waveform_rd_addr, spectrum_rd_addr;
    wire waveform_write, spectrum_write;
    wire [10:0] waveform_wr_addr, spectrum_wr_addr;
    wire [15:0] waveform_wr_data, spectrum_wr_data;
    wire requested_view = latest_r[500];
    wire build_fire = pcm_window_valid && pcm_window_ready;
    wire wave_busy = waveform_busy || spectrum_busy;
    wire wave_done = waveform_done || spectrum_done;
    wire wave_valid = cache_valid_r;
    wire [31:0] wave_seq = cache_view_r ? spectrum_seq : waveform_seq;
    wire [15:0] wave_peak = cache_view_r ? spectrum_peak : waveform_peak;
    localparam CACHE_COLUMNS = (WAVE_COLUMNS>=1 && WAVE_COLUMNS<=1024) ? WAVE_COLUMNS : 1;
    wire scene_request = have_state_r && (dirty_r || wave_done) && !wave_busy &&
        (!pcm_window_valid || wave_pending_r || wave_done);
    wire build_enable = (state == IDLE) && !scene_request && !wave_busy;
    wire column_read_allowed = (state == WAIT_RENDER) || ((state == SEND_SCENE) && out_ready);
    reg [21:0] active_mask;
    reg expiring;
    // Sequential updates below are already excluded by asynchronous reset.
    // Keep public ready low in reset; do not route rst_n through timer CEs.
    wire input_fire = display_in_valid && !configuration_error;
    wire [21:0] input_activity = display_in_state[477:456] | display_in_state[499:478];
    wire [21:0] input_reset = display_in_state[499:478];
    integer i;
    integer k;
    assign configuration_error = (CLK_SYS_HZ < 1000) || (HIGHLIGHT_MS < 1) ||
        (HIGHLIGHT_MS > 65535) || wave_configuration_error || spectrum_configuration_error;
    assign display_in_ready = rst_n && !configuration_error;
    assign scene_state = scene_r;
    assign highlight_mask = highlight_r;
    assign default_mask = defaults_r;
    assign out_valid = (state == SEND_SCENE);
    assign protocol_error = protocol_error_r || pcm_protocol_error || wave_protocol_error;
    assign scene_wave_valid = scene_wave_valid_r;
    assign scene_pcm_valid = scene_pcm_valid_r;
    assign scene_spectrum_valid = scene_spectrum_valid_r;
    assign scene_spectrum_seq = scene_wave_seq_r;
    assign scene_spectrum_clipped = scene_spectrum_clipped_r;
    assign scene_fft_overflow = scene_fft_overflow_r;
    assign scene_wave_seq = scene_wave_seq_r;
    assign scene_output_peak = scene_output_peak_r;
    assign scene_dropped_windows = scene_dropped_windows_r;
    assign pcm_window_ready = requested_view ? spectrum_ready : waveform_ready;
    assign pcm_rd_en = cache_view_r ? spectrum_read : waveform_read;
    assign pcm_rd_addr = cache_view_r ? spectrum_rd_addr : waveform_rd_addr;
    assign pcm_release = cache_view_r ? spectrum_release : waveform_release;

    lcd_pcm_capture lcd_pcm_capture_u (
        .clk_sys(clk_sys), .rst_n(rst_n), .audio_in(audio_in),
        .in_valid(audio_in_valid), .in_ready(audio_in_ready),
        .window_valid(pcm_window_valid), .window_ready(pcm_window_ready),
        .window_seq(pcm_window_seq), .window_release(pcm_release),
        .rd_en(pcm_rd_en), .rd_addr(pcm_rd_addr), .rd_data(pcm_rd_data),
        .dropped_windows(dropped_windows), .protocol_error(pcm_protocol_error)
    );
    lcd_waveform_builder #(
        .WAVE_COLUMNS(WAVE_COLUMNS), .GRAPH_Y_MIN(GRAPH_Y_MIN), .GRAPH_Y_MAX(GRAPH_Y_MAX),
        .EXTERNAL_COLUMNS(1)
    ) lcd_waveform_builder_u (
        .clk_sys(clk_sys), .rst_n(rst_n), .build_enable(build_enable),
        .start_valid(pcm_window_valid && !requested_view), .start_ready(waveform_ready), .window_seq(pcm_window_seq),
        .pcm_rd_en(waveform_read), .pcm_rd_addr(waveform_rd_addr), .pcm_rd_data(pcm_rd_data),
        .window_release(waveform_release), .busy(waveform_busy), .wave_done(waveform_done),
        .wave_valid(waveform_valid), .wave_seq(waveform_seq), .wave_peak(waveform_peak),
        .column_rd_en(1'b0), .column_rd_addr(11'd0), .column_rd_data(),
        .column_wr_en(waveform_write), .column_wr_addr(waveform_wr_addr), .column_wr_data(waveform_wr_data),
        .protocol_error(wave_protocol_error), .configuration_error(wave_configuration_error)
    );
    lcd_spectrum_builder #(
        .WAVE_COLUMNS(WAVE_COLUMNS), .GRAPH_Y_MIN(GRAPH_Y_MIN), .GRAPH_Y_MAX(GRAPH_Y_MAX),
        .SAMPLE_RATE_NUM(SPECTRUM_SAMPLE_RATE_NUM), .SAMPLE_RATE_DEN(SPECTRUM_SAMPLE_RATE_DEN),
        .FREQ_VIEW_MAX_HZ(SPECTRUM_MAX_HZ)
    ) lcd_spectrum_builder_u (
        .clk_sys(clk_sys), .rst_n(rst_n), .build_enable(build_enable),
        .start_valid(pcm_window_valid && requested_view), .start_ready(spectrum_ready), .window_seq(pcm_window_seq),
        .pcm_rd_en(spectrum_read), .pcm_rd_addr(spectrum_rd_addr), .pcm_rd_data(pcm_rd_data),
        .window_release(spectrum_release), .busy(spectrum_busy), .spectrum_done(spectrum_done),
        .spectrum_valid(spectrum_valid), .spectrum_seq(spectrum_seq), .spectrum_peak(spectrum_peak),
        .spectrum_clipped(spectrum_clipped), .fft_overflow(spectrum_overflow),
        .column_wr_en(spectrum_write), .column_wr_addr(spectrum_wr_addr), .column_wr_data(spectrum_wr_data),
        .configuration_error(spectrum_configuration_error)
    );
    lcd_sdp_ram #(.DATA_WIDTH(16), .DEPTH(2*CACHE_COLUMNS), .ADDR_WIDTH(11)) graph_columns_u (
        .clk(clk_sys), .rst_n(rst_n), .wr_en(waveform_write || spectrum_write),
        .wr_addr(cache_view_r ? spectrum_wr_addr : waveform_wr_addr),
        .wr_data(cache_view_r ? spectrum_wr_data : waveform_wr_data),
        .rd_en(column_rd_en && column_read_allowed && (scene_wave_valid_r || scene_spectrum_valid_r) &&
            column_rd_addr < 2*WAVE_COLUMNS), .rd_addr(column_rd_addr), .rd_data(column_rd_data)
    );

    fsm #(.W(2), .INITIAL_STATE(IDLE)) fsm_u (
        .clk(clk_sys), .rst_n(rst_n), .stn(next_state), .stc(state)
    );
    always @(*)
    begin
        next_state = state;
        case (state)
            IDLE: if (scene_request) next_state = FREEZE_SCENE;
            FREEZE_SCENE: next_state = SEND_SCENE;
            SEND_SCENE:
                if (out_ready) next_state = render_done ? IDLE : WAIT_RENDER;
            WAIT_RENDER: if (render_done) next_state = IDLE;
            default: next_state = IDLE;
        endcase
    end
    always @(*)
    begin
        active_mask = 22'd0;
        expiring = 1'b0;
        for (k = 0; k < 22; k = k + 1)
        begin
            active_mask[k] = (remaining_r[k] != {TIMER_WIDTH{1'b0}});
            if (remaining_r[k] == {{(TIMER_WIDTH-1){1'b0}},1'b1}) expiring = 1'b1;
        end
    end
    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            latest_r <= 545'd0;
            scene_r <= 545'd0;
            have_state_r <= 1'b0;
            dirty_r <= 1'b0;
            ms_count_r <= {MS_WIDTH{1'b0}};
            highlight_r <= 22'd0;
            defaults_r <= 22'd0;
            reset_latched_r <= 22'd0;
            pending_activity_r <= 22'd0;
            pending_reset_r <= 22'd0;
            protocol_error_r <= 1'b0;
            wave_pending_r <= 1'b0;
            scene_wave_valid_r <= 1'b0;
            scene_pcm_valid_r <= 1'b0;
            scene_spectrum_valid_r <= 1'b0;
            scene_spectrum_clipped_r <= 1'b0;
            scene_fft_overflow_r <= 1'b0;
            cache_view_r <= 1'b0;
            cache_valid_r <= 1'b0;
            scene_wave_seq_r <= 32'd0;
            scene_output_peak_r <= 16'd0;
            scene_dropped_windows_r <= 32'd0;
            for (i = 0; i < 22; i = i + 1) remaining_r[i] <= {TIMER_WIDTH{1'b0}};
        end
        else
        begin
            if (ms_tick) ms_count_r <= {MS_WIDTH{1'b0}};
            else ms_count_r <= ms_count_r + 1'b1;
            for (i = 0; i < 22; i = i + 1)
            begin
                if (ms_tick && remaining_r[i] != {TIMER_WIDTH{1'b0}})
                    remaining_r[i] <= remaining_r[i] - 1'b1;
                if (input_fire && input_activity[i])
                begin
                    remaining_r[i] <= HIGHLIGHT_MS;
                    reset_latched_r[i] <= input_reset[i];
                end
                if (state == FREEZE_SCENE && pending_activity_r[i])
                begin
                    remaining_r[i] <= HIGHLIGHT_MS;
                    reset_latched_r[i] <= pending_reset_r[i];
                end
            end
            if (state == FREEZE_SCENE)
            begin
                scene_r <= latest_r;
                highlight_r <= active_mask | pending_activity_r;
                defaults_r <= (active_mask & reset_latched_r & ~pending_activity_r) | pending_reset_r;
                dirty_r <= 1'b0;
                pending_activity_r <= 22'd0;
                pending_reset_r <= 22'd0;
                scene_wave_valid_r <= wave_valid && !cache_view_r && !latest_r[500];
                scene_spectrum_valid_r <= wave_valid && cache_view_r && latest_r[500];
                scene_pcm_valid_r <= wave_valid;
                scene_spectrum_clipped_r <= wave_valid && cache_view_r && latest_r[500] && spectrum_clipped;
                scene_fft_overflow_r <= wave_valid && cache_view_r && latest_r[500] && spectrum_overflow;
                scene_wave_seq_r <= wave_seq;
                scene_output_peak_r <= wave_peak;
                scene_dropped_windows_r <= dropped_windows;
                wave_pending_r <= 1'b0;
            end
            if (ms_tick && expiring) dirty_r <= 1'b1;
            // One completed build gets a scene before another queued build.
            // This avoids starving render jobs even under a synthetic 1/cycle
            // PCM stream; real I2S supplies one sample per2048 system clocks.
            if (wave_done)
            begin
                dirty_r <= 1'b1;
                wave_pending_r <= 1'b1;
                cache_valid_r <= 1'b1;
            end
            if (build_fire)
            begin
                cache_view_r <= requested_view;
                cache_valid_r <= 1'b0;
            end
            // Input wins a coincident freeze/expiry: it stays pending for the
            // next job, never mutates the already frozen output scene.
            if (input_fire)
            begin
                latest_r <= display_in_state;
                have_state_r <= 1'b1;
                dirty_r <= 1'b1;
                pending_activity_r <= ((state == FREEZE_SCENE) ? 22'd0 : pending_activity_r) | input_activity;
                pending_reset_r <= ((state == FREEZE_SCENE) ? 22'd0 : pending_reset_r) | input_reset;
                if (display_in_state[510] && display_in_state[422:420] != 3'd1)
                    protocol_error_r <= 1'b1;
            end
            if (render_done && state != WAIT_RENDER && !(state == SEND_SCENE && out_ready))
                protocol_error_r <= 1'b1;
            if (column_rd_en && (!column_read_allowed || !(scene_wave_valid_r || scene_spectrum_valid_r) ||
                column_rd_addr >= 2*WAVE_COLUMNS))
                protocol_error_r <= 1'b1;
            if (waveform_busy && spectrum_busy) protocol_error_r <= 1'b1;
        end
    end
endmodule
