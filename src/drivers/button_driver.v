/**
 * 四路独立按键驱动：输入同步、扫描消抖、整组状态帧输出。
 */

/**
 * clk_sys: 系统时钟，默认 98.304 MHz；所有时序逻辑工作在上升沿。
 * rst_n: 低电平有效异步复位。
 * scan_tick_up: 与 clk_sys 同步的单周期扫描脉冲，默认 12 kHz。
 * button_pins[0..3]: B1..B4 的物理输入，高电平表示按下。
 * button_states[0..3]: 已消抖的 B1..B4 状态，1 表示按下。
 * out_valid && out_ready: 在同一 clk_sys 上升沿交付整组状态。
 * out_valid 为 1 且 out_ready 为 0 时，button_states 保持不变。
 * 每次扫描产生一帧；背压时保留正在发送的帧，未发送的扫描帧合并为最新状态。
 * 因此长时间背压可能合并多次按放，接收端需要及时消费状态帧。
 * DEBOUNCE_CYCLES: 每键按下和释放都要稳定的系统周期数，默认 98304，即 1 ms。
 * 首次采到新电平后开始计时，仅在后续扫描沿确认；实际延迟最多再增加扫描间隔。
 */
module button_driver
#(
    parameter integer DEBOUNCE_CYCLES = 98_304
)(
    input clk_sys,
    input rst_n,
    input scan_tick_up,
    input [3:0] button_pins,
    input out_ready,
    output [3:0] button_states,
    output out_valid
);
    localparam integer COUNT_W = DEBOUNCE_CYCLES < 2 ? 1 :
                                 $clog2(DEBOUNCE_CYCLES + 1);
    localparam [COUNT_W-1:0] DEBOUNCE_LAST =
        DEBOUNCE_CYCLES > 0 ? DEBOUNCE_CYCLES - 1 : 0;

    wire [3:0] button_sync;
    reg [3:0] filtered_state_r, candidate_valid_r;
    reg [COUNT_W-1:0] stable_count_r [0:3];
    reg [3:0] button_states_r;
    reg out_valid_r, frame_pending_r;

    signal_sync #(
        .W(4), .INITIAL_VALUE(4'd0)
    ) button_sync_u (
        .clk(clk_sys), .rst_n(rst_n),
        .signal_in(button_pins), .signal_out(button_sync)
    );

    assign button_states = button_states_r;
    assign out_valid = out_valid_r;

    integer i;
    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            filtered_state_r <= 4'd0;
            candidate_valid_r <= 4'd0;
            for (i = 0; i < 4; i = i + 1)
                stable_count_r[i] <= '0;
        end
        else
        begin
            for (i = 0; i < 4; i = i + 1)
            begin
                if (scan_tick_up)
                begin
                    if (button_sync[i] == filtered_state_r[i])
                    begin
                        candidate_valid_r[i] <= 1'b0;
                        stable_count_r[i] <= '0;
                    end
                    else if (DEBOUNCE_CYCLES == 0)
                    begin
                        filtered_state_r[i] <= button_sync[i];
                        candidate_valid_r[i] <= 1'b0;
                        stable_count_r[i] <= '0;
                    end
                    else if (!candidate_valid_r[i])
                    begin
                        candidate_valid_r[i] <= 1'b1;
                        stable_count_r[i] <= '0;
                    end
                    else if (stable_count_r[i] >= DEBOUNCE_LAST)
                    begin
                        filtered_state_r[i] <= button_sync[i];
                        candidate_valid_r[i] <= 1'b0;
                        stable_count_r[i] <= '0;
                    end
                    else
                        stable_count_r[i] <= stable_count_r[i] + 1'b1;
                end
                else if (candidate_valid_r[i] && stable_count_r[i] < DEBOUNCE_CYCLES)
                    stable_count_r[i] <= stable_count_r[i] + 1'b1;
            end
        end
    end

    // 输出槽和一位待发送标志足够表达最新状态；扫描和通信互不阻塞。
    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            button_states_r <= 4'd0;
            out_valid_r <= 1'b0;
            frame_pending_r <= 1'b0;
        end
        else
        begin
            if (scan_tick_up)
                frame_pending_r <= 1'b1;
            if (out_valid_r && out_ready)
                out_valid_r <= 1'b0;
            if ((!out_valid_r || out_ready) && (frame_pending_r || scan_tick_up))
            begin
                button_states_r <= filtered_state_r;
                out_valid_r <= 1'b1;
                frame_pending_r <= 1'b0;
            end
        end
    end
endmodule
