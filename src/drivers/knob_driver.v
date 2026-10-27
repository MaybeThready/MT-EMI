/**
 * 八旋钮驱动：三片 74HC165 串行扫描、AB 四相解码、按键消抖和有序事件缓冲。
 * 
 */

/**
 * clk_sys / rst_n: 系统时钟 / 低有效异步复位；scan_tick_up 与该时钟同步。
 * serial_data / load_n / shift_clk: 分别接 PCB J1.7 / J1.3 / J1.5；PCB 以 3.3V 供电。
 * 24 位串行顺序为 A8..A1、B8..B1、SW8..SW1，各组最低位对应 K1。
 * scan_tick_up 每 SYS_CLK_HZ/SCAN_HZ 个系统周期出现一次，复位后首次时间不限。
 * knob_states[i]: 本次握手交付一步转动，连续两次握手为 1 表示两步，不是保持态。
 * knob_dirs[i]: 对应步的方向，1 增加、0 减少；states=0 时方向没有业务意义。
 * knob_pressed[i]: 已消抖的保持态，1 按下；bit0..7 对应 PCB K1..K8。
 * out_valid && out_ready: 上升沿交付整组载荷；等待时 valid 和载荷保持不变。
 * overflow: 事件队列满时丢弃新事件帧并锁存，复位清除；扫描继续。
 * scan_error: tick 间隔错误/扫描忙时重入/漏 tick，复位清除；丢弃部分位移并重新同步。
 *
 * KNOB_NUM: 使用 K1 起连续的 1..8 个旋钮，物理链始终采集全部 24 位。
 * SYS_CLK_HZ / SCAN_HZ: 实际系统频率 / 扫描频率，须为正整数且整除。
 * DEBOUNCE_TICKS / RELEASE_TICKS: 按下/释放稳定时间，单位 clk_sys 周期，向上取整到扫描间隔。
 * LOAD_CYCLES / SHIFT_HALF_CYCLES: 装载保持/移位半周期，单位 clk_sys 周期；默认均为 16。
 * 装载至少 1 周期、移位半周期至少 2 周期，实际取值还须满足 74HC165 的传播与建立时间。
 * TRANSITIONS_PER_STEP: 1/2/4 个有效 AB 跃迁对应一步，默认 4；与 UI 的 WAVE_SELECT_STEPS 不同。
 * 默认正向 {A,B}: 00->01->11->10->00；实物方向相反时设置 DIRECTION_INVERT 对应位。
 * PRESSED_ACTIVE_LOW: PCB 默认 1，即 SW 原始低电平表示按下。
 * EVENT_FIFO_DEPTH: 待发送事件帧数量，另有一个冻结输出槽；有限容量由 overflow 明确告警。
 * 首次输出等待全部按键初始消抖完成，正确报告上电已按住状态；启动期间不报告转动。
 * AB 不使用毫秒级按键消抖；合法反向跃迁撤销部分位移，双位跳变清除部分计数。
 * 1 跃迁模式会逐边沿报告触点往返，机械编码器通常应按实际定位结构选择 2 或 4。
 * 空闲时发布 states=0 的状态帧；背压期间仅缓存转动/按键变化，保留方向和按放顺序。
 * 顶层须将本帧与其他外设整理后交付 UI，已消费的旋转事件不能重复发送。
 */
module knob_driver
#(
    parameter integer KNOB_NUM = 8,
    parameter integer SYS_CLK_HZ = 98_304_000,
    parameter integer SCAN_HZ = 12_000,
    parameter integer DEBOUNCE_TICKS = 98_304,
    parameter integer RELEASE_TICKS = DEBOUNCE_TICKS,
    parameter integer SHIFT_HALF_CYCLES = 16,
    parameter integer LOAD_CYCLES = 16,
    parameter integer TRANSITIONS_PER_STEP = 4,
    parameter [KNOB_NUM-1:0] DIRECTION_INVERT = {KNOB_NUM{1'b0}},
    parameter PRESSED_ACTIVE_LOW = 1'b1,
    parameter integer EVENT_FIFO_DEPTH = 32
)(
    input clk_sys,
    input rst_n,
    input scan_tick_up,
    input serial_data,
    input out_ready,
    output load_n,
    output shift_clk,
    output [KNOB_NUM-1:0] knob_states,
    output [KNOB_NUM-1:0] knob_dirs,
    output [KNOB_NUM-1:0] knob_pressed,
    output out_valid,
    output overflow,
    output scan_error
);
    localparam integer SCAN_CYCLES = (SCAN_HZ > 0 && SYS_CLK_HZ >= SCAN_HZ) ? SYS_CLK_HZ / SCAN_HZ : 1;
    // 仅常量除法；计数的是完整扫描间隔，不对 AB 延迟毫秒级消抖。
    localparam [63:0] PRESS_SCANS = (64'd0 + DEBOUNCE_TICKS + SCAN_CYCLES - 1) / SCAN_CYCLES;
    localparam [63:0] RELEASE_SCANS = (64'd0 + RELEASE_TICKS + SCAN_CYCLES - 1) / SCAN_CYCLES;
    localparam [63:0] MAX_SCANS = (PRESS_SCANS > RELEASE_SCANS) ? PRESS_SCANS : RELEASE_SCANS;
    localparam integer FILTER_W = (MAX_SCANS < 2) ? 1 : $clog2(MAX_SCANS + 64'd1);
    localparam integer PTR_W = (EVENT_FIFO_DEPTH < 2) ? 1 : $clog2(EVENT_FIFO_DEPTH);
    localparam integer COUNT_W = (EVENT_FIFO_DEPTH < 2) ? 1 : $clog2(EVENT_FIFO_DEPTH + 64'd1);
    localparam integer PAYLOAD_W = 3 * KNOB_NUM;
    localparam signed [3:0] POSITIVE_LAST = TRANSITIONS_PER_STEP - 1;
    localparam signed [3:0] NEGATIVE_LAST = 1 - TRANSITIONS_PER_STEP;

    wire [23:0] frame_data;
    wire frame_valid;
    wire history_break;
    wire [KNOB_NUM-1:0] filtered_pressed;
    wire [KNOB_NUM-1:0] button_initialized;
    wire [KNOB_NUM-1:0] step_events;
    wire [KNOB_NUM-1:0] step_dirs;
    wire buttons_ready;
    reg decoded_valid_r;

    // 三片 74HC165
    localparam integer BIT_NUM = 24;
    localparam integer BIT_W = $clog2(BIT_NUM);
    localparam integer WAIT_MAX = (SHIFT_HALF_CYCLES > LOAD_CYCLES) ? SHIFT_HALF_CYCLES : LOAD_CYCLES;
    localparam integer TIMER_W = (WAIT_MAX < 2) ? 1 : $clog2(WAIT_MAX);
    localparam integer AGE_W = (SCAN_CYCLES < 2) ? 1 : $clog2(SCAN_CYCLES + 64'd1);
    localparam [63:0] MIN_SCAN_CYCLES = LOAD_CYCLES +
        (64'd2 * BIT_NUM - 64'd1) * SHIFT_HALF_CYCLES + BIT_NUM + 64'd2;
    localparam [2:0]
        S_WAIT_SCAN = 3'd0,         // 空闲，等待下一次完整扫描
        S_PARALLEL_LOAD = 3'd1,     // /PL 保持低，装载全部并行输入
        S_WAIT_FIRST_DATA = 3'd2,   // /PL 释放后等待首位及同步器稳定
        S_SAMPLE_BIT = 3'd3,        // 采样当前 Q7，最后一位后发布完整帧
        S_SHIFT_HIGH = 3'd4,        // 移位上升沿后保持高电平
        S_SHIFT_LOW = 3'd5;         // 保持低电平并等待下一位稳定

    wire [2:0] stc;
    reg [2:0] stn;
    reg [TIMER_W-1:0] timer_r;
    reg [BIT_W-1:0] bit_index_r;
    reg [BIT_NUM-1:0] shift_r;
    reg [BIT_NUM-1:0] frame_data_r;
    reg frame_valid_r;
    reg frame_usable_r;
    reg load_n_r;
    reg shift_clk_r;
    reg scan_started_r;
    reg [AGE_W-1:0] scan_age_r;
    reg scan_error_r;
    wire data_sync;
    wire scan_start;

    assign load_n = load_n_r;
    assign shift_clk = shift_clk_r;
    assign frame_data = frame_data_r;
    assign frame_valid = frame_valid_r;
    assign scan_error = scan_error_r;
    assign scan_start = scan_tick_up && (stc == S_WAIT_SCAN);
    assign history_break =
        (scan_tick_up && ((stc != S_WAIT_SCAN) ||
        (scan_started_r && scan_age_r != SCAN_CYCLES - 1))) ||
        (scan_started_r && scan_age_r >= SCAN_CYCLES);

    signal_sync #(
        .W(1), .INITIAL_VALUE(1'b1)
    ) data_sync_u (
        .clk(clk_sys), .rst_n(rst_n),
        .signal_in(serial_data), .signal_out(data_sync)
    );

    fsm #(
        .W(3), .INITIAL_STATE(S_WAIT_SCAN)
    ) fsm_u (
        .clk(clk_sys), .rst_n(rst_n), .stn(stn), .stc(stc)
    );

    always @(*)
    begin
        case (stc)
            S_WAIT_SCAN: stn = scan_start ? S_PARALLEL_LOAD : S_WAIT_SCAN;
            S_PARALLEL_LOAD:
                stn = (timer_r == LOAD_CYCLES - 1) ? S_WAIT_FIRST_DATA : S_PARALLEL_LOAD;
            S_WAIT_FIRST_DATA:
                stn = (timer_r == SHIFT_HALF_CYCLES - 1) ? S_SAMPLE_BIT : S_WAIT_FIRST_DATA;
            S_SAMPLE_BIT:
                stn = (bit_index_r == BIT_NUM - 1) ? S_WAIT_SCAN : S_SHIFT_HIGH;
            S_SHIFT_HIGH:
                stn = (timer_r == SHIFT_HALF_CYCLES - 1) ? S_SHIFT_LOW : S_SHIFT_HIGH;
            S_SHIFT_LOW:
                stn = (timer_r == SHIFT_HALF_CYCLES - 1) ? S_SAMPLE_BIT : S_SHIFT_LOW;
            default: stn = S_WAIT_SCAN;
        endcase
    end

    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            scan_started_r <= 1'b0;
            scan_age_r <= '0;
            scan_error_r <= 1'b0;
            frame_usable_r <= 1'b0;
        end
        else
        begin
            if (scan_start)
            begin
                scan_started_r <= 1'b1;
                scan_age_r <= '0;
                frame_usable_r <= 1'b1;
            end
            else
            begin
                if (scan_started_r && scan_age_r < SCAN_CYCLES)
                    scan_age_r <= scan_age_r + 1'b1;
                if (history_break)
                    frame_usable_r <= 1'b0;
            end
            if (history_break)
                scan_error_r <= 1'b1;
        end
    end

    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            timer_r <= '0;
            bit_index_r <= '0;
            shift_r <= '0;
            frame_data_r <= '0;
            frame_valid_r <= 1'b0;
            load_n_r <= 1'b1;
            shift_clk_r <= 1'b0;
        end
        else
        begin
            frame_valid_r <= 1'b0;
            case (stc)
                S_WAIT_SCAN:
                begin
                    load_n_r <= 1'b1;
                    shift_clk_r <= 1'b0;
                    if (scan_start)
                    begin
                        load_n_r <= 1'b0;
                        timer_r <= '0;
                        bit_index_r <= '0;
                        shift_r <= '0;
                    end
                end
                S_PARALLEL_LOAD:
                begin
                    if (timer_r == LOAD_CYCLES - 1)
                    begin
                        load_n_r <= 1'b1;
                        timer_r <= '0;
                    end
                    else
                        timer_r <= timer_r + 1'b1;
                end
                S_WAIT_FIRST_DATA:
                begin
                    if (timer_r == SHIFT_HALF_CYCLES - 1)
                        timer_r <= '0;
                    else
                        timer_r <= timer_r + 1'b1;
                end
                S_SAMPLE_BIT:
                begin
                    shift_r <= (shift_r << 1) | data_sync;
                    if (bit_index_r == BIT_NUM - 1)
                    begin
                        frame_data_r <= (shift_r << 1) | data_sync;
                        frame_valid_r <= frame_usable_r && !history_break;
                    end
                    else
                    begin
                        shift_clk_r <= 1'b1;
                        timer_r <= '0;
                    end
                end
                S_SHIFT_HIGH:
                begin
                    if (timer_r == SHIFT_HALF_CYCLES - 1)
                    begin
                        shift_clk_r <= 1'b0;
                        timer_r <= '0;
                    end
                    else
                        timer_r <= timer_r + 1'b1;
                end
                S_SHIFT_LOW:
                begin
                    if (timer_r == SHIFT_HALF_CYCLES - 1)
                    begin
                        bit_index_r <= bit_index_r + 1'b1;
                        timer_r <= '0;
                    end
                    else
                        timer_r <= timer_r + 1'b1;
                end
                default:
                begin
                    load_n_r <= 1'b1;
                    shift_clk_r <= 1'b0;
                    timer_r <= '0;
                    bit_index_r <= '0;
                end
            endcase
        end
    end

    // 二位补码 01/11 表示 +1/-1 次有效跃迁，00 表示不动或非法跃迁。
    function signed [1:0] phase_movement;
        input [1:0] previous_ab;
        input [1:0] current_ab;
        begin
            case ({previous_ab, current_ab})
                4'b0001, 4'b0111, 4'b1110, 4'b1000: phase_movement = 2'sd1;
                4'b0010, 4'b1011, 4'b1101, 4'b0100: phase_movement = -2'sd1;
                default: phase_movement = 2'sd0;
            endcase
        end
    endfunction

    assign buttons_ready = &button_initialized;
    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
            decoded_valid_r <= 1'b0;
        else
            decoded_valid_r <= frame_valid && !history_break;
    end

    genvar lane;
    generate
        for (lane = 0; lane < KNOB_NUM; lane = lane + 1)
        begin : g_knob
            wire [1:0] raw_ab = {frame_data[16+lane], frame_data[8+lane]};
            wire raw_pressed = frame_data[lane] ^ PRESSED_ACTIVE_LOW;
            wire [63:0] required_scans = raw_pressed ? PRESS_SCANS : RELEASE_SCANS;
            reg pressed_r;
            reg initialized_r;
            reg candidate_r;
            reg candidate_valid_r;
            reg [FILTER_W-1:0] stable_intervals_r;
            reg [1:0] previous_ab_r;
            reg ab_history_valid_r;
            reg signed [3:0] partial_r;
            reg step_r;
            reg dir_r;
            wire signed [1:0] movement = phase_movement(previous_ab_r, raw_ab);

            assign filtered_pressed[lane] = pressed_r;
            assign button_initialized[lane] = initialized_r;
            assign step_events[lane] = step_r;
            assign step_dirs[lane] = dir_r;

            always @(posedge clk_sys or negedge rst_n)
            begin
                if (!rst_n)
                begin
                    pressed_r <= 1'b0;
                    initialized_r <= 1'b0;
                    candidate_r <= 1'b0;
                    candidate_valid_r <= 1'b0;
                    stable_intervals_r <= '0;
                    previous_ab_r <= 2'b11;
                    ab_history_valid_r <= 1'b0;
                    partial_r <= 4'sd0;
                    step_r <= 1'b0;
                    dir_r <= 1'b0;
                end
                else
                begin
                    step_r <= 1'b0;
                    if (history_break)
                    begin
                        candidate_valid_r <= 1'b0;
                        stable_intervals_r <= '0;
                        ab_history_valid_r <= 1'b0;
                        partial_r <= 4'sd0;
                    end
                    else if (frame_valid)
                    begin
                        if (!candidate_valid_r || candidate_r != raw_pressed)
                        begin
                            candidate_r <= raw_pressed;
                            candidate_valid_r <= 1'b1;
                            stable_intervals_r <= '0;
                            if (required_scans == 0)
                            begin
                                pressed_r <= raw_pressed;
                                initialized_r <= 1'b1;
                            end
                        end
                        else if (!initialized_r || pressed_r != raw_pressed)
                        begin
                            if (required_scans == 0 || stable_intervals_r >= required_scans - 1)
                            begin
                                pressed_r <= raw_pressed;
                                initialized_r <= 1'b1;
                                stable_intervals_r <= '0;
                            end
                            else
                                stable_intervals_r <= stable_intervals_r + 1'b1;
                        end
                        else
                            stable_intervals_r <= '0;

                        previous_ab_r <= raw_ab;
                        ab_history_valid_r <= 1'b1;
                        if (!ab_history_valid_r || !buttons_ready ||
                            ((previous_ab_r ^ raw_ab) == 2'b11))
                            partial_r <= 4'sd0;
                        else if (movement == 2'sd1)
                        begin
                            if (partial_r == POSITIVE_LAST)
                            begin
                                partial_r <= 4'sd0;
                                step_r <= 1'b1;
                                dir_r <= 1'b1 ^ DIRECTION_INVERT[lane];
                            end
                            else
                                partial_r <= partial_r + 4'sd1;
                        end
                        else if (movement == -2'sd1)
                        begin
                            if (partial_r == NEGATIVE_LAST)
                            begin
                                partial_r <= 4'sd0;
                                step_r <= 1'b1;
                                dir_r <= DIRECTION_INVERT[lane];
                            end
                            else
                                partial_r <= partial_r - 4'sd1;
                        end
                    end
                end
            end
        end
    endgenerate

    reg [PAYLOAD_W-1:0] event_fifo_r [0:EVENT_FIFO_DEPTH-1];
    reg [PTR_W-1:0] write_ptr_r;
    reg [PTR_W-1:0] read_ptr_r;
    reg [COUNT_W-1:0] queue_count_r;
    reg [PAYLOAD_W-1:0] output_payload_r;
    reg out_valid_r;
    reg overflow_r;
    reg baseline_queued_r;
    reg [KNOB_NUM-1:0] last_queued_pressed_r;
    wire report_frame;
    wire important_frame;
    wire output_slot_ready;
    wire pop_event;
    wire bypass_event;
    wire push_event;
    wire [PAYLOAD_W-1:0] report_payload;

    assign report_frame = decoded_valid_r && buttons_ready && !history_break;
    assign important_frame = report_frame && (!baseline_queued_r ||
        (|step_events) || filtered_pressed != last_queued_pressed_r);
    assign output_slot_ready = !out_valid_r || out_ready;
    assign pop_event = output_slot_ready && (queue_count_r != 0);
    assign bypass_event = important_frame && output_slot_ready && (queue_count_r == 0);
    assign push_event = important_frame && !bypass_event &&
        ((queue_count_r < EVENT_FIFO_DEPTH) || pop_event);
    assign report_payload = {step_events, step_dirs & step_events, filtered_pressed};
    assign out_valid = rst_n && out_valid_r;
    assign knob_states = output_payload_r[3*KNOB_NUM-1:2*KNOB_NUM];
    assign knob_dirs = output_payload_r[2*KNOB_NUM-1:KNOB_NUM];
    assign knob_pressed = output_payload_r[KNOB_NUM-1:0];
    assign overflow = overflow_r;

    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            write_ptr_r <= '0;
            read_ptr_r <= '0;
            queue_count_r <= '0;
            output_payload_r <= '0;
            out_valid_r <= 1'b0;
            overflow_r <= 1'b0;
            baseline_queued_r <= 1'b0;
            last_queued_pressed_r <= '0;
        end
        else
        begin
            // 只有空槽或已握手时可替换输出；入队不能改变正在等待的载荷。
            if (output_slot_ready)
            begin
                if (pop_event)
                begin
                    output_payload_r <= event_fifo_r[read_ptr_r];
                    out_valid_r <= 1'b1;
                end
                else if (report_frame)
                begin
                    output_payload_r <= report_payload;
                    out_valid_r <= 1'b1;
                end
                else
                    out_valid_r <= 1'b0;
            end

            if (pop_event)
                read_ptr_r <= (read_ptr_r == EVENT_FIFO_DEPTH - 1) ? '0 : read_ptr_r + 1'b1;
            if (push_event)
            begin
                event_fifo_r[write_ptr_r] <= report_payload;
                write_ptr_r <= (write_ptr_r == EVENT_FIFO_DEPTH - 1) ? '0 : write_ptr_r + 1'b1;
            end
            case ({push_event, pop_event})
                2'b10: queue_count_r <= queue_count_r + 1'b1;
                2'b01: queue_count_r <= queue_count_r - 1'b1;
                default: queue_count_r <= queue_count_r;
            endcase

            if (bypass_event || push_event)
            begin
                baseline_queued_r <= 1'b1;
                last_queued_pressed_r <= filtered_pressed;
            end
            if (important_frame && !bypass_event && !push_event)
                overflow_r <= 1'b1;
        end
    end

    // synthesis translate_off
    initial
    begin
        if (KNOB_NUM < 1 || KNOB_NUM > 8 || SYS_CLK_HZ <= 0 || SCAN_HZ <= 0 ||
            DEBOUNCE_TICKS < 0 || RELEASE_TICKS < 0 || EVENT_FIFO_DEPTH < 1)
            $fatal(1, "knob_driver: invalid count, frequency, debounce or FIFO depth");
        else if (SYS_CLK_HZ % SCAN_HZ != 0 ||
            (TRANSITIONS_PER_STEP != 1 && TRANSITIONS_PER_STEP != 2 && TRANSITIONS_PER_STEP != 4))
            $fatal(1, "knob_driver: non-integral scan period or invalid transitions per step");
        else if (SHIFT_HALF_CYCLES < 2 || LOAD_CYCLES < 1 || SCAN_CYCLES < MIN_SCAN_CYCLES)
            $fatal(1, "knob_driver: invalid serial scan timing");
    end
    // synthesis translate_on
endmodule
