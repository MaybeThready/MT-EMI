/**
 * 八旋钮上板测试：三片74HC165 -> 原knob_driver -> 原knob_event_handler -> LED。
 * LED0..2显示最近操作的零基旋钮号，LED3方向，LED4任意按住，LED5事件/故障。
 */
/**
 * clk_core为板载50MHz；rst_n接S0，低有效。
 * serial_data接PCB J1.7，load_n接J1.3，shift_clk接J1.5，PCB使用3.3V。
 * TRANSITIONS_PER_STEP默认4：一个完整AB脉冲输出一步，不按未知的定位格数猜测。
 * DIRECTION_INVERT每位置1可反转对应K1..K8方向；PRESSED_ACTIVE_LOW默认1。
 * LED均低亮：0/1/2的亮灯权值为1/2/4，相加再加1得到K1..K8。
 * LED3显示最近一次转动方向，增加亮、减少灭；按压不改变方向显示。
 * LED4表示至少一个旋钮按住；LED5在转动、按下、松开时亮约200ms。
 * overflow或scan_error使LED5锁存常亮，S0清除；首次状态帧不作为按压动作。
 */
module test_knob_driver
#(
    parameter integer TRANSITIONS_PER_STEP = 4,
    parameter [7:0] DIRECTION_INVERT = 8'h00,
    parameter PRESSED_ACTIVE_LOW = 1'b1
)(
    input clk_core,
    input rst_n,
    input serial_data,
    output load_n,
    output shift_clk,
    output [5:0] status_led
);
    wire clk_sys, rst_sys_n;

    sys_clocker sys_clocker_u (
        .clk_core(clk_core), .rst_n(rst_n), .clk_sys(clk_sys), .rst_sys_n(rst_sys_n)
    );

    test_knob_driver_core #(
        .TRANSITIONS_PER_STEP(TRANSITIONS_PER_STEP), .DIRECTION_INVERT(DIRECTION_INVERT),
        .PRESSED_ACTIVE_LOW(PRESSED_ACTIVE_LOW)
    ) test_knob_driver_core_u (
        .clk_sys(clk_sys), .rst_n(rst_sys_n), .serial_data(serial_data), .monitor_ready(1'b1),
        .load_n(load_n), .shift_clk(shift_clk), .status_led(status_led)
    );
endmodule

/**
 * 与板载PLL分离的测试核心；使用原sys_ticker产生12kHz同步扫描脉冲。
 * monitor_ready是观察端ready，上板接1，仿真可拉低验证事件排队和输出保持。
 * DEBOUNCE_TICKS为clk_sys周期数；EVENT_LED_SCANS为事件灯保持的扫描周期数。
 * 同帧多个旋钮动作时，LED编号显示其中编号最大的一个，事件本身全部交付。
 */
module test_knob_driver_core
#(
    parameter integer TRANSITIONS_PER_STEP = 4,
    parameter [7:0] DIRECTION_INVERT = 8'h00,
    parameter PRESSED_ACTIVE_LOW = 1'b1,
    parameter integer DEBOUNCE_TICKS = 98304,
    parameter integer EVENT_LED_SCANS = 2400
)(
    input clk_sys,
    input rst_n,
    input serial_data,
    input monitor_ready,
    output load_n,
    output shift_clk,
    output [5:0] status_led
);
    localparam integer LED_TIMER_W = (EVENT_LED_SCANS < 2) ? 1 : $clog2(EVENT_LED_SCANS + 64'd1);
    wire scan_tick_up;
    wire [7:0] knob_states, knob_dirs, knob_pressed;
    wire driver_valid, driver_ready, driver_overflow, scan_error;
    wire signed [1:0] knob_delta [7:0];
    wire [7:0] knob_pressed_event;
    wire event_valid, event_fire;
    wire [7:0] changed_buttons, activity;
    reg [7:0] pressed_snapshot_r, pressed_levels_r;
    reg levels_initialized_r;
    reg [2:0] selected_knob_r;
    reg last_direction_r;
    reg [LED_TIMER_W-1:0] event_timer_r;
    reg fault_r;
    integer lane;
    genvar key;

    sys_ticker sys_ticker_u (
        .clk_sys(clk_sys), .rst_n(rst_n),
        .i2s_tick_up(), .i2s_tick_down(), .smp_tick_up(), .smp_tick_down(),
        .scan_tick_up(scan_tick_up), .scan_tick_down()
    );

    knob_driver #(
        .KNOB_NUM(8), .DEBOUNCE_TICKS(DEBOUNCE_TICKS),
        .TRANSITIONS_PER_STEP(TRANSITIONS_PER_STEP), .DIRECTION_INVERT(DIRECTION_INVERT),
        .PRESSED_ACTIVE_LOW(PRESSED_ACTIVE_LOW)
    ) knob_driver_u (
        .clk_sys(clk_sys), .rst_n(rst_n), .scan_tick_up(scan_tick_up), .serial_data(serial_data),
        .out_ready(driver_ready), .load_n(load_n), .shift_clk(shift_clk),
        .knob_states(knob_states), .knob_dirs(knob_dirs), .knob_pressed(knob_pressed),
        .out_valid(driver_valid), .overflow(driver_overflow), .scan_error(scan_error)
    );

    knob_event_handler #(.KNOB_NUM(8)) knob_event_handler_u (
        .clk_sys(clk_sys), .rst_n(rst_n), .scan_tick_up(scan_tick_up),
        .knob_states(knob_states), .knob_dirs(knob_dirs), .knob_pressed(knob_pressed),
        .knob_delta(knob_delta), .knob_pressed_event(knob_pressed_event),
        .in_valid(driver_valid), .in_ready(driver_ready),
        .out_valid(event_valid), .out_ready(monitor_ready)
    );

    assign event_fire = event_valid && monitor_ready;
    assign changed_buttons = levels_initialized_r ? (pressed_snapshot_r ^ pressed_levels_r) : 8'd0;
    generate
        for (key = 0; key < 8; key = key + 1)
        begin : g_activity
            // 按下使用真实UI通知；松开由同帧保持态变化识别。
            assign activity[key] = (knob_delta[key] != 2'sd0) || knob_pressed_event[key] ||
                (changed_buttons[key] && !pressed_snapshot_r[key]);
        end
    endgenerate

    // 按住状态与handler中的本帧delta一同冻结，不能旁路读取下一帧状态。
    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
            pressed_snapshot_r <= 8'd0;
        else if (driver_valid && driver_ready)
            pressed_snapshot_r <= knob_pressed;
    end

    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            pressed_levels_r <= 8'd0;
            levels_initialized_r <= 1'b0;
            selected_knob_r <= 3'd0;
            last_direction_r <= 1'b0;
            event_timer_r <= '0;
            fault_r <= 1'b0;
        end
        else
        begin
            if (scan_tick_up && event_timer_r != 0)
                event_timer_r <= event_timer_r - 1'b1;
            if (driver_overflow || scan_error)
                fault_r <= 1'b1;
            if (event_fire)
            begin
                pressed_levels_r <= pressed_snapshot_r;
                levels_initialized_r <= 1'b1;
                if (|activity)
                    event_timer_r <= EVENT_LED_SCANS;
                for (lane = 0; lane < 8; lane = lane + 1)
                begin
                    if (activity[lane])
                        selected_knob_r <= lane;
                    if (knob_delta[lane] != 2'sd0)
                        last_direction_r <= (knob_delta[lane] == 2'sd1);
                end
            end
        end
    end

    assign status_led[2:0] = ~selected_knob_r;
    assign status_led[3] = !last_direction_r;
    assign status_led[4] = !(|pressed_levels_r);
    assign status_led[5] = !(fault_r || (event_timer_r != 0));

    // synthesis translate_off
    initial
    begin
        if (EVENT_LED_SCANS < 1 || DEBOUNCE_TICKS < 0)
            $fatal(1, "test_knob_driver: invalid LED/debounce time");
    end
    // synthesis translate_on
endmodule
