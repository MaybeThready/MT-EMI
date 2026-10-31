/**
 * 双板24键触摸驱动V1.0：串行采样、逐键消抖和状态帧输出。
 * 每板两片级联74HC165，串行顺序为 [无效4位,K12,...,K1]。
 * TODO: 当前仅采集触摸开关状态，力度使用DEFAULT_VELOCITY占位。
 * 后续需根据真实压力硬件接入采集。
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
 * key_velocity: 24个UQ0.16力度值；当前全部为DEFAULT_VELOCITY。
 * out_valid: 输出帧有效；out_valid与out_ready在同一系统时钟
 *            上升沿同时为1时完成传输。
 * out_valid为1且out_ready为0期间，输出帧保持不变。
 * 扫描和消抖不受out_ready影响，积压帧合并为最近的完整过滤状态。
 * 本接口不保证接收端观察到长时间背压期间的每一次按下、松开转换。
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
    parameter [15:0] DEFAULT_VELOCITY = 16'hFFFF // UQ0.16
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
    output out_valid
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
    reg frame_pending;
    wire [1:0] data_sync;
    wire scan_start, history_break, frame_complete;
    wire [KEY_NUM-1:0] raw_keys;
    integer i;
    genvar k;

    assign load_n = load_n_r;
    assign key_clk = key_clk_r;
    assign key_states = key_states_r;
    assign out_valid = out_valid_r;
    assign raw_keys = {board_b, board_a};


    assign scan_start = (stc == S_IDLE) && scan_tick_up;
    assign history_break = (scan_tick_up && !scan_start) ||
                           (scan_age >= SCAN_CYCLES);
    assign frame_complete = (stc == S_FRAME_DONE);

    generate
        
        if (KEY_NUM != 24 || SYS_CLK_HZ <= 0 || SCAN_HZ <= 0 ||
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
            assign key_velocity[k] = DEFAULT_VELOCITY;
        end
    endgenerate

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

    // 独立输出槽在背压期间保持稳定，积压帧合并为最近过滤状态。
    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            key_states_r <= {KEY_NUM{1'b0}};
            out_valid_r <= 1'b0;
            frame_pending <= 1'b0;
        end
        else
        begin
            if (frame_complete)
                frame_pending <= 1'b1;

            if (out_valid_r && out_ready)
                out_valid_r <= 1'b0;

            
            if ((!out_valid_r || out_ready) &&
                (frame_pending || frame_complete))
            begin
                key_states_r <= filtered_state;
                out_valid_r <= 1'b1;
                frame_pending <= 1'b0;
            end
        end
    end

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
