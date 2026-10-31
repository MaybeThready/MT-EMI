/**
 * 双板24键触摸驱动V1.0：串行采样、逐键消抖和状态帧输出。
 * 每板两片级联74HC165，串行顺序为 [无效4位,K12,...,K1]。
 * 两片4067按16+8路扫描全部FSR，与24键下标一一对应。
 */
/**
 * clk_sys: 系统时钟，默认98.304MHz；所有时序逻辑工作在其上升沿。
 * rst_n: 低电平有效异步复位。
 * scan_tick_up: 与clk_sys同步的单周期扫描脉冲，默认12kHz。
 * data_a/data_b: A、B键盘板的74HC165串行输出，1表示按下。
 * load_n: 74HC165低电平有效并行装载信号。
 * key_clk: 74HC165移位时钟，上升沿使串行数据移动一位。
 * out_ready: 后级准备好接收输出帧。
 * key_states: 24位按键状态；A-K1..K12对应位0..11，
 *             B-K1..K12对应位12..23。
 * key_velocity: 24个UQ0.16力度值；所有琴键按住时持续更新压力。
 * 未按下键为0；24键状态/力度的数组下标和UI接口不变。
 * PRESSURE_ENABLE=0仅用于旧硬件回归，此时仍输出DEFAULT_VELOCITY。
 * mux_addr[0..3]共接两片S0..S3；mux_en_a_n/mux_en_b_n分别接低有效EN。
 * 第一片Y0..15对应key0..15，第二片Y0..7对应key16..23，其余通道不扫描。
 * ADCV接模拟前端缩放后的单路压力电压，详见keyboard_adc接口说明。
 * adc_error为ADC超时锁存标志；错误半帧不交付，自动复位ADC并从键0重扫。
 * PRESSURE_ZERO_CODES/FULL_CODES: 每键14位ADC码，最低14位对应键0；
 * 默认0/1690对应松开高阻、10kΩ下拉和缓冲后1/4缩放；须按实测逐键校准。
 * 触摸每12kHz独立消抖；压力24路顺序采样，完整组刷新率低于scan_tick_up。
 * 触摸变化立即携带当时最近完整压力快照排队，不等待下一轮ADC；首次完整压力前为0。
 * 仅整组压力更新缓存，半组/故障结果不交付；压力刷新可以合并，触摸边沿保留顺序。
 * out_valid: 输出帧有效；out_valid与out_ready在同一系统时钟
 *            上升沿同时为1时完成传输。
 * out_valid为1且out_ready为0期间，输出帧保持不变。
 * EVENT_FIFO_DEPTH: 压力模式下触摸状态变化快照的FIFO深度，默认16组，支持任意正整数。
 * event_overflow: FIFO满且不能同拍出入队时丢弃新变化并锁存1，复位清除。
 * 超容量不保证保留全部历史动作；有空间后重试当前状态，压力采集和消抖始终继续。
 * PRESSURE_ENABLE=0保留旧触摸模式的最新状态合并行为，event_overflow恒0。
 * SYS_CLK_HZ/SCAN_HZ必须与真实时钟及tick间隔一致，并且整除。
 * 扫描间隔至少为LOAD_CYCLES + 31*SHIFT_HALF_CYCLES + 19个系统周期。
 */

module keyboard_driver
#(
    parameter integer KEY_NUM = 24,              // 按键数量，固定24键
    parameter integer SYS_CLK_HZ = 98_304_000,   // >0，实际系统时钟频率，单位Hz
    parameter integer SCAN_HZ = 12_000,          // >0，须整除SYS_CLK_HZ，单位Hz
    parameter integer DEBOUNCE_TICKS = 98_304,   // >=0，按下消抖系统周期数
    parameter integer RELEASE_TICKS = DEBOUNCE_TICKS, // >=0，释放消抖系统周期数
    parameter integer SHIFT_HALF_CYCLES = 16,    // >=2，移位电平等待周期数，须满足硬件时序
    parameter integer LOAD_CYCLES = 16,          // >=1，并行装载系统周期数，须满足硬件时序
    parameter [15:0] DEFAULT_VELOCITY = 16'hFFFF, // UQ0.16，仅旧硬件模式固定力度
    parameter integer PRESSURE_ENABLE = 1,      // 1启用ADC压力，0仅旧硬件回归
    parameter integer EVENT_FIFO_DEPTH = 16,
    parameter integer ADC_CLK_DIV = 64,         // 偶数，默认ADC时钟1.536MHz
    parameter integer ADC_STARTUP_TICKS = 98_304, // ADC使能后等待，单位系统周期
    parameter integer ADC_TIMEOUT_TICKS = 4096 * ADC_CLK_DIV,
    parameter integer ADC_SAMPLE_COUNT_SEL = 1, // 厂商编码，128点
    parameter integer ADC_RATE_CHANGE_SEL = 2,  // 厂商编码，16周期
    parameter integer MUX_BREAK_TICKS = 16,     // 改地址前模块关闭的系统周期数
    parameter integer ADDRESS_SETUP_TICKS = 16, // 改地址至使能的系统周期数
    parameter integer MUX_SETTLE_TICKS = 4916,  // 模拟稳定约50us，须按实际前端验证
    parameter integer ADC_DISCARD_SAMPLES = 1,  // 每个通道切换后丢弃完整转换数
    parameter [KEY_NUM*14-1:0] PRESSURE_ZERO_CODES = {KEY_NUM{14'd0}},
    parameter [KEY_NUM*14-1:0] PRESSURE_FULL_CODES = {KEY_NUM{14'd1690}},
    parameter integer PRESSURE_DEADBAND_CODE = 8,
    parameter [9:0] ADC_FSCAL_VALUE = 10'd653,
    parameter [11:0] ADC_OFFSET_VALUE = 12'd0
)(
    input clk_sys,
    input rst_n,
    input scan_tick_up,
    input data_a,
    input data_b,
    input out_ready,
    output load_n,
    output key_clk,
    output [KEY_NUM-1:0] key_states,
    output [15:0] key_velocity [KEY_NUM-1:0],
    output out_valid,
    output [3:0] mux_addr,
    output mux_en_a_n,
    output mux_en_b_n,
    output adc_error,
    output event_overflow
);
    localparam integer SCAN_CYCLES = (SCAN_HZ > 0 && SYS_CLK_HZ >= SCAN_HZ) ? SYS_CLK_HZ / SCAN_HZ : 1;
    localparam integer MAX_TICKS = (DEBOUNCE_TICKS > RELEASE_TICKS) ? DEBOUNCE_TICKS : RELEASE_TICKS;
    localparam integer CNT_W = (MAX_TICKS < 2) ? 1 : $clog2(MAX_TICKS + 64'd1);
    localparam integer WAIT_MAX = (SHIFT_HALF_CYCLES > LOAD_CYCLES) ? SHIFT_HALF_CYCLES : LOAD_CYCLES;
    localparam integer TIMER_W = (WAIT_MAX < 2) ? 1 : $clog2(WAIT_MAX + 64'd1);
    localparam integer SCAN_W = (SCAN_CYCLES < 2) ? 1 : $clog2(SCAN_CYCLES + 64'd1);
    localparam [63:0] MIN_SCAN_CYCLES = 64'd19 + LOAD_CYCLES + 64'd31 * SHIFT_HALF_CYCLES;
    localparam [CNT_W-1:0] PRESS_LAST = (DEBOUNCE_TICKS > 0) ? DEBOUNCE_TICKS - 1 : 0;
    localparam [CNT_W-1:0] RELEASE_LAST = (RELEASE_TICKS > 0) ? RELEASE_TICKS - 1 : 0;
    localparam [CNT_W-1:0] COUNT_LIMIT = (MAX_TICKS > 0) ? MAX_TICKS : 0;
    localparam [2:0]
        S_IDLE         = 3'd0, // 等待扫描tick
        S_LOAD_ACTIVE  = 3'd1, // load_n保持低，执行并行装载
        S_WAIT_DATA    = 3'd2, // 装载结束，等待串行数据经过同步器
        S_SAMPLE_BIT   = 3'd3, // 采样当前串行位
        S_SHIFT_HIGH   = 3'd4, // 移位时钟高电平保持阶段
        S_SHIFT_LOW    = 3'd5, // 移位时钟低电平等待阶段
        S_FILTER_FRAME = 3'd6, // 对完整采样帧执行逐键消抖
        S_FRAME_DONE   = 3'd7; // 过滤完成，通知独立输出逻辑

    wire [2:0] stc;
    reg [2:0] stn;
    reg [TIMER_W-1:0] timer;
    reg [4:0] bit_index;
    reg [15:0] shift_a, shift_b;
    reg [11:0] board_a, board_b;
    reg [KEY_NUM-1:0] filtered_state, candidate_valid;
    reg [CNT_W-1:0] stable_count [KEY_NUM-1:0];
    reg [SCAN_W-1:0] scan_age;
    reg load_n_r, key_clk_r, out_valid_r;
    reg [KEY_NUM-1:0] key_states_r;
    wire frame_pending;
    wire [1:0] data_sync;
    wire scan_start, history_break, frame_complete;
    wire [KEY_NUM-1:0] raw_keys;
    wire pressure_frame_done;
    wire [15:0] pressure_velocity [KEY_NUM-1:0];
    reg pressure_frame_complete_r;
    reg [15:0] latest_velocity_r [KEY_NUM-1:0];
    reg [15:0] key_velocity_r [KEY_NUM-1:0];
    integer output_index;
    integer snapshot_index;
    integer i;
    genvar k;
    genvar lane;

    assign load_n = load_n_r;
    assign key_clk = key_clk_r;
    assign key_states = key_states_r;
    assign out_valid = out_valid_r;
    assign raw_keys = {board_b, board_a};


    assign scan_start = (stc == S_IDLE) && scan_tick_up;
    assign history_break = (scan_tick_up && !scan_start) ||
                           (scan_age >= SCAN_CYCLES);
    assign frame_complete = PRESSURE_ENABLE ? pressure_frame_complete_r : (stc == S_FRAME_DONE);

    generate

        if (KEY_NUM != 24 || EVENT_FIFO_DEPTH < 1 || (PRESSURE_ENABLE != 0 && PRESSURE_ENABLE != 1) || SYS_CLK_HZ <= 0 || SCAN_HZ <= 0 ||
            DEBOUNCE_TICKS < 0 || RELEASE_TICKS < 0 || LOAD_CYCLES < 1)
        begin : g_invalid_parameters
            initial
            begin
                $fatal(1, "keyboard_driver: invalid key count, frequency or timing parameter");
            end
        end

        else if (SHIFT_HALF_CYCLES < 2)
        begin : g_invalid_shift_wait
            initial
            begin
                $fatal(1, "keyboard_driver: SHIFT_HALF_CYCLES must be at least 2");
            end
        end
        else if ((SYS_CLK_HZ % SCAN_HZ) != 0 || SCAN_CYCLES < MIN_SCAN_CYCLES)
        begin : g_invalid_scan_period
            initial
            begin
                $fatal(1, "keyboard_driver: scan period must be integral and fit the scan FSM");
            end
        end

        for (k = 0; k < KEY_NUM; k = k + 1)
        begin
            assign key_velocity[k] = PRESSURE_ENABLE ? key_velocity_r[k] : DEFAULT_VELOCITY;
        end
    endgenerate

    generate
        if (PRESSURE_ENABLE)
        begin : g_pressure
            keyboard_pressure_scanner #(
                .KEY_NUM(KEY_NUM),
                .SYS_CLK_HZ(SYS_CLK_HZ), .ADC_CLK_DIV(ADC_CLK_DIV),
                .ADC_STARTUP_TICKS(ADC_STARTUP_TICKS), .ADC_TIMEOUT_TICKS(ADC_TIMEOUT_TICKS),
                .ADC_SAMPLE_COUNT_SEL(ADC_SAMPLE_COUNT_SEL), .ADC_RATE_CHANGE_SEL(ADC_RATE_CHANGE_SEL),
                .MUX_BREAK_TICKS(MUX_BREAK_TICKS), .ADDRESS_SETUP_TICKS(ADDRESS_SETUP_TICKS),
                .MUX_SETTLE_TICKS(MUX_SETTLE_TICKS), .ADC_DISCARD_SAMPLES(ADC_DISCARD_SAMPLES),
                .ZERO_CODES(PRESSURE_ZERO_CODES), .FULL_CODES(PRESSURE_FULL_CODES),
                .DEAD_BAND_CODE(PRESSURE_DEADBAND_CODE),
                .ADC_FSCAL_VALUE(ADC_FSCAL_VALUE), .ADC_OFFSET_VALUE(ADC_OFFSET_VALUE)
            ) keyboard_pressure_scanner_u (
                .clk_sys(clk_sys), .rst_n(rst_n), .scan_tick_up(scan_tick_up),
                .mux_addr(mux_addr), .mux_en_a_n(mux_en_a_n), .mux_en_b_n(mux_en_b_n),
                .velocity(pressure_velocity), .frame_done(pressure_frame_done), .adc_error(adc_error)
            );
        end
        else
        begin : g_legacy
            assign mux_addr = 4'd0;
            assign mux_en_a_n = 1'b1;
            assign mux_en_b_n = 1'b1;
            assign adc_error = 1'b0;
            assign pressure_frame_done = 1'b0;
            for (lane = 0; lane < KEY_NUM; lane = lane + 1)
            begin : g_unused_pressure
                assign pressure_velocity[lane] = 16'd0;
            end
        end
    endgenerate

    // 只锁存已完成的24路压力；不在此处采样触摸，避免慢ADC吞掉触摸边沿。
    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            pressure_frame_complete_r <= 1'b0;
            for (snapshot_index = 0; snapshot_index < KEY_NUM; snapshot_index = snapshot_index + 1)
                latest_velocity_r[snapshot_index] <= 16'd0;
        end
        else
        begin
            pressure_frame_complete_r <= pressure_frame_done;
            if (pressure_frame_done)
            begin
                for (snapshot_index = 0; snapshot_index < KEY_NUM; snapshot_index = snapshot_index + 1)
                begin
                    latest_velocity_r[snapshot_index] <= pressure_velocity[snapshot_index];
                end
            end
        end
    end

    signal_sync #(
        .W(2),
        .INITIAL_VALUE(2'b00)
    ) data_sync_u (
        .clk(clk_sys),
        .rst_n(rst_n),
        .signal_in({data_b, data_a}),
        .signal_out(data_sync)
    );

    // 状态转换：复用公共状态寄存器。
    fsm #(
        .W(3),
        .INITIAL_STATE(S_IDLE)
    ) fsm_u (
        .clk(clk_sys),
        .rst_n(rst_n),
        .stn(stn),
        .stc(stc)
    );

    // 状态转移
    always @(*)
    begin
        stn = stc;
        case (stc)
            S_IDLE: stn = scan_start ? S_LOAD_ACTIVE : S_IDLE;
            S_LOAD_ACTIVE: stn = (timer == LOAD_CYCLES - 1) ? S_WAIT_DATA : S_LOAD_ACTIVE;
            S_WAIT_DATA: stn = (timer == SHIFT_HALF_CYCLES - 1) ? S_SAMPLE_BIT : S_WAIT_DATA;
            S_SAMPLE_BIT: stn = (bit_index == 5'd15) ? S_FILTER_FRAME : S_SHIFT_HIGH;
            S_SHIFT_HIGH: stn = (timer == SHIFT_HALF_CYCLES - 1) ? S_SHIFT_LOW : S_SHIFT_HIGH;
            S_SHIFT_LOW: stn = (timer == SHIFT_HALF_CYCLES - 1) ? S_SAMPLE_BIT : S_SHIFT_LOW;
            S_FILTER_FRAME: stn = S_FRAME_DONE;
            S_FRAME_DONE: stn = S_IDLE;
            default: stn = S_IDLE;
        endcase
    end
    // 状态输出：只负责外设控制和串行采样。

    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            timer <= '0;
            bit_index <= 5'd0;
            load_n_r <= 1'b1;
            key_clk_r <= 1'b0;
            shift_a <= 16'd0;
            shift_b <= 16'd0;
            board_a <= 12'd0;
            board_b <= 12'd0;
        end
        else
        begin
            case (stc)
                S_IDLE:
                begin
                    load_n_r <= 1'b1;
                    key_clk_r <= 1'b0;
                    if (scan_start)
                    begin
                        load_n_r <= 1'b0;
                        shift_a <= 16'd0;
                        shift_b <= 16'd0;
                        bit_index <= 5'd0;
                        timer <= '0;
                    end
                end

                S_LOAD_ACTIVE:
                begin
                    if (timer == LOAD_CYCLES - 1)
                    begin
                        load_n_r <= 1'b1;
                        timer <= '0;
                    end
                    else
                        timer <= timer + 1'b1;
                end

                S_WAIT_DATA:
                begin
                    if (timer == SHIFT_HALF_CYCLES - 1)
                        timer <= '0;
                    else
                        timer <= timer + 1'b1;
                end

                S_SAMPLE_BIT:
                begin
                    shift_a <= {shift_a[14:0], data_sync[0]};
                    shift_b <= {shift_b[14:0], data_sync[1]};
                    if (bit_index == 5'd15)
                    begin
                        // 丢弃前四个无效位，保留最后十二位K12..K1。
                        board_a <= {shift_a[10:0], data_sync[0]};
                        board_b <= {shift_b[10:0], data_sync[1]};
                    end
                    else
                    begin
                        key_clk_r <= 1'b1;
                        timer <= '0;
                    end
                end

                S_SHIFT_HIGH:
                begin
                    if (timer == SHIFT_HALF_CYCLES - 1)
                    begin
                        key_clk_r <= 1'b0;
                        timer <= '0;
                    end
                    else
                        timer <= timer + 1'b1;
                end

                S_SHIFT_LOW:
                begin
                    if (timer == SHIFT_HALF_CYCLES - 1)
                    begin
                        bit_index <= bit_index + 1'b1;
                        timer <= '0;
                    end
                    else
                        timer <= timer + 1'b1;
                end

                S_FILTER_FRAME: timer <= '0;
                S_FRAME_DONE: timer <= '0;

                default:
                begin
                    load_n_r <= 1'b1;
                    key_clk_r <= 1'b0;
                    timer <= '0;
                end
            endcase
        end
    end

    generate
        if (PRESSURE_ENABLE)
        begin : g_event_output
            localparam integer PAYLOAD_W = KEY_NUM * 17;
            localparam integer PTR_W = (EVENT_FIFO_DEPTH > 1) ? $clog2(EVENT_FIFO_DEPTH) : 1;
            localparam integer COUNT_W = $clog2(EVENT_FIFO_DEPTH + 64'd1);
            reg [PAYLOAD_W-1:0] event_fifo [0:EVENT_FIFO_DEPTH-1];
            reg [PTR_W-1:0] read_ptr_r, write_ptr_r;
            reg [COUNT_W-1:0] count_r;
            reg [KEY_NUM-1:0] last_queued_state_r;
            reg state_initialized_r;
            reg refresh_pending_r;
            reg event_overflow_r;
            wire touch_frame_done;
            wire output_available;
            wire event_needed, direct_event, fifo_pop, fifo_push;
            wire event_accepted;
            wire [PAYLOAD_W-1:0] current_payload;
            wire [PAYLOAD_W-1:0] head_payload;
            genvar event_lane;

            assign event_overflow = event_overflow_r;
            assign frame_pending = refresh_pending_r || (count_r != 0);
            assign touch_frame_done = (stc == S_FRAME_DONE);
            assign output_available = !out_valid_r || out_ready;
            assign event_needed = touch_frame_done &&
                                  (!state_initialized_r || filtered_state != last_queued_state_r);
            assign fifo_pop = output_available && (count_r != 0);
            assign direct_event = event_needed && output_available && (count_r == 0);
            assign fifo_push = event_needed && !direct_event &&
                               ((count_r < EVENT_FIFO_DEPTH) || fifo_pop);
            assign event_accepted = direct_event || fifo_push;
            assign current_payload[PAYLOAD_W-1 -: KEY_NUM] = filtered_state;
            assign head_payload = event_fifo[read_ptr_r];

            for (event_lane = 0; event_lane < KEY_NUM; event_lane = event_lane + 1)
            begin : g_event_payload
                assign current_payload[event_lane*16 +: 16] = filtered_state[event_lane] ?
                    latest_velocity_r[event_lane] : 16'd0;
            end

            function [PTR_W-1:0] next_pointer;
                input [PTR_W-1:0] pointer;
                begin
                    next_pointer = (pointer == EVENT_FIFO_DEPTH - 1) ? '0 : pointer + 1'b1;
                end
            endfunction

            // 事件FIFO仅保存触摸变化；压力刷新合并，避免空闲帧挤占事件队列。
            // 输出槽独立冻结；FIFO满但同拍出队时，仍可接收新的触摸变化。
            always @(posedge clk_sys or negedge rst_n)
            begin
                if (!rst_n)
                begin
                    read_ptr_r <= '0;
                    write_ptr_r <= '0;
                    count_r <= '0;
                    last_queued_state_r <= '0;
                    state_initialized_r <= 1'b0;
                    refresh_pending_r <= 1'b0;
                    event_overflow_r <= 1'b0;
                    key_states_r <= '0;
                    out_valid_r <= 1'b0;
                    for (output_index = 0; output_index < KEY_NUM; output_index = output_index + 1)
                        key_velocity_r[output_index] <= 16'd0;
                end
                else
                begin
                    if (touch_frame_done || pressure_frame_complete_r)
                        refresh_pending_r <= 1'b1;
                    if (out_valid_r && out_ready)
                        out_valid_r <= 1'b0;

                    if (event_accepted)
                    begin
                        last_queued_state_r <= filtered_state;
                        state_initialized_r <= 1'b1;
                    end
                    else if (event_needed)
                        event_overflow_r <= 1'b1;

                    if (fifo_push)
                    begin
                        event_fifo[write_ptr_r] <= current_payload;
                        write_ptr_r <= next_pointer(write_ptr_r);
                    end
                    if (fifo_pop)
                        read_ptr_r <= next_pointer(read_ptr_r);
                    case ({fifo_push, fifo_pop})
                        2'b10: count_r <= count_r + 1'b1;
                        2'b01: count_r <= count_r - 1'b1;
                        default: count_r <= count_r;
                    endcase

                    if (fifo_pop)
                    begin
                        key_states_r <= head_payload[PAYLOAD_W-1 -: KEY_NUM];
                        for (output_index = 0; output_index < KEY_NUM; output_index = output_index + 1)
                            key_velocity_r[output_index] <= head_payload[output_index*16 +: 16];
                        out_valid_r <= 1'b1;
                    end
                    else if (direct_event)
                    begin
                        key_states_r <= filtered_state;
                        for (output_index = 0; output_index < KEY_NUM; output_index = output_index + 1)
                            key_velocity_r[output_index] <= current_payload[output_index*16 +: 16];
                        out_valid_r <= 1'b1;
                    end
                    else if (output_available && refresh_pending_r && state_initialized_r)
                    begin
                        // 不能越过排队事件；到这里FIFO已空，只更新已排队最终状态的压力。
                        key_states_r <= last_queued_state_r;
                        for (output_index = 0; output_index < KEY_NUM; output_index = output_index + 1)
                            key_velocity_r[output_index] <= last_queued_state_r[output_index] ?
                                latest_velocity_r[output_index] : 16'd0;
                        out_valid_r <= 1'b1;
                        refresh_pending_r <= 1'b0;
                    end
                end
            end
        end
        else
        begin : g_legacy_output
            reg frame_pending_r;
            assign frame_pending = frame_pending_r;
            assign event_overflow = 1'b0;

            // 保留旧硬件模式的最新状态合并协议，便于原有触摸回归。
            always @(posedge clk_sys or negedge rst_n)
            begin
                if (!rst_n)
                begin
                    key_states_r <= '0;
                    out_valid_r <= 1'b0;
                    frame_pending_r <= 1'b0;
                    for (output_index = 0; output_index < KEY_NUM; output_index = output_index + 1)
                        key_velocity_r[output_index] <= 16'd0;
                end
                else
                begin
                    if (frame_complete)
                        frame_pending_r <= 1'b1;
                    if (out_valid_r && out_ready)
                        out_valid_r <= 1'b0;
                    if ((!out_valid_r || out_ready) && (frame_pending_r || frame_complete))
                    begin
                        key_states_r <= filtered_state;
                        out_valid_r <= 1'b1;
                        frame_pending_r <= 1'b0;
                    end
                end
            end
        end
    endgenerate

    // 扫描间隔监测，饱和计数避免溢出。
    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
            scan_age <= '0;
        else if (scan_tick_up)
            scan_age <= '0;
        else if (scan_age < SCAN_CYCLES)
            scan_age <= scan_age + 1'b1;
    end

    // 每键独立计量系统周期，仅在完整采样处确认状态变化。
    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            filtered_state <= {KEY_NUM{1'b0}};
            candidate_valid <= {KEY_NUM{1'b0}};
            for (i = 0; i < KEY_NUM; i = i + 1)
                stable_count[i] <= '0;
        end
        else
        begin
            for (i = 0; i < KEY_NUM; i = i + 1)
            begin
                if (history_break)
                begin
                    candidate_valid[i] <= 1'b0;
                    stable_count[i] <= '0;
                end
                else if (stc == S_FILTER_FRAME)
                begin
                    if (raw_keys[i] == filtered_state[i])
                    begin
                        candidate_valid[i] <= 1'b0;
                        stable_count[i] <= '0;
                    end
                    else if ((raw_keys[i] && DEBOUNCE_TICKS == 0) ||
                             (!raw_keys[i] && RELEASE_TICKS == 0))
                    begin
                        filtered_state[i] <= raw_keys[i];
                        candidate_valid[i] <= 1'b0;
                        stable_count[i] <= '0;
                    end
                    else if (!candidate_valid[i])
                    begin
                        candidate_valid[i] <= 1'b1;
                        stable_count[i] <= '0;
                    end
                    else if ((raw_keys[i] && stable_count[i] >= PRESS_LAST) ||
                             (!raw_keys[i] && stable_count[i] >= RELEASE_LAST))
                    begin
                        // 当前沿完成下一周期，因此比较TICKS-1。
                        filtered_state[i] <= raw_keys[i];
                        candidate_valid[i] <= 1'b0;
                        stable_count[i] <= '0;
                    end
                    else
                        stable_count[i] <= stable_count[i] + 1'b1;
                end
                else if (candidate_valid[i] && stable_count[i] < COUNT_LIMIT)
                    stable_count[i] <= stable_count[i] + 1'b1;
            end
        end
    end
endmodule
