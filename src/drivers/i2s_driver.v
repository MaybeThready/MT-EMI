/**
 * MAX98357A I2S 驱动， 采用单声道
 * 左声道发送单声道 SQ1.15 采样，右声道发送静音，每声道 16 位，最高位先发
 */

/**
 * clk_sys / rst_n: 系统时钟 / 低有效异步复位。
 * i2s_tick_up / i2s_tick_down: 同步于 clk_sys 的 BCLK 上升 / 下降沿事件。
 * smp_tick_up: 每帧起点，与 i2s_tick_down 同拍；每帧包含 32 个 BCLK 周期。
 * 三个 tick 必须来自同一 sys_ticker，驱动与 sys_ticker 应使用同一复位。
 * 默认 clk_sys = 98.304 MHz，BCLK = 1.536 MHz，LRCK = 48 kHz。
 *
 * audio_data: 16 位二进制补码音频，SQ1.15，范围 [-1, 1)。
 * in_valid / in_ready: 在 clk_sys 上升沿同时为 1 时接收一个采样。
 * 每帧只在 smp_tick_up 后第一个 i2s_tick_up 拉高 in_ready 一个 clk_sys 周期。
 * 上游应提前准备好上一采样周期的结果，并保持 valid 和数据直到握手；
 * 此时距帧起点 32 个 clk_sys 周期，距发送最高位还有 32 个周期。
 *
 * i2s_bclk: 连续位时钟；复位后等待首个 smp_tick_up 再启动。
 * i2s_lrck: 低电平表示左声道，高电平表示右声道；先于最高位一个 BCLK 切换。
 * i2s_dout: 仅在 i2s_tick_down 更新，MAX98357A 在 BCLK 上升沿采样。
 * MAX98357A 必须配置为左声道输出（SD_MODE 高电平，具体接法按模块原理图）。
 */
module i2s_driver
(
    input clk_sys,
    input rst_n,
    input i2s_tick_up,
    input i2s_tick_down,
    input smp_tick_up,
    input signed [15:0] audio_data,
    input in_valid,
    output i2s_bclk,
    output i2s_lrck,
    output i2s_dout,
    output sd_mode_n,
    output in_ready
);
    localparam [1:0]
        S_WAIT_FRAME = 2'd0,   // 等待完整帧起点
        S_WAIT_SAMPLE = 2'd1,  // 等待帧起点后的第一个 BCLK 上升沿，接收采样
        S_SEND_LEFT = 2'd2,    // 在下降沿依次输出左声道 D15..D0
        S_SEND_RIGHT = 2'd3; // 在下降沿发送右声道的 16 位静音数据

    wire [1:0] stc;
    reg [1:0] stn;
    reg [3:0] bit_count;      // 当前声道已发送位数
    reg [15:0] sample_shift;
    reg i2s_bclk_r;
    reg i2s_lrck_r;
    reg i2s_dout_r;

    assign i2s_bclk = i2s_bclk_r;
    assign i2s_lrck = i2s_lrck_r;
    assign i2s_dout = i2s_dout_r;
    assign in_ready = rst_n && (stc == S_WAIT_SAMPLE) && i2s_tick_up;

    // 状态转换
    fsm #(
        .W(2),
        .INITIAL_STATE(S_WAIT_FRAME)
    ) fsm_u (
        .clk(clk_sys),
        .rst_n(rst_n),
        .stn(stn),
        .stc(stc)
    );


    always @(*)
    begin
        if (smp_tick_up)
            stn = S_WAIT_SAMPLE;
        else
        begin
            case (stc)
                S_WAIT_FRAME: stn = S_WAIT_FRAME;
                S_WAIT_SAMPLE: stn = i2s_tick_up ? S_SEND_LEFT : S_WAIT_SAMPLE;
                S_SEND_LEFT:
                    stn = (i2s_tick_down && bit_count == 4'd15) ? S_SEND_RIGHT : S_SEND_LEFT;
                S_SEND_RIGHT:
                    stn = (i2s_tick_down && bit_count == 4'd15) ? S_WAIT_FRAME : S_SEND_RIGHT;
                default: stn = S_WAIT_FRAME;
            endcase
        end
    end


    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
            i2s_bclk_r <= 1'b0;
        else if (stc == S_WAIT_FRAME)
            i2s_bclk_r <= 1'b0;
        else if (i2s_tick_up)
            i2s_bclk_r <= 1'b1;
        else if (i2s_tick_down)
            i2s_bclk_r <= 1'b0;
    end

    // 状态输出：先接收完整采样，再依次发送左声道音频和右声道静音。
    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            bit_count <= 4'd0;
            sample_shift <= 16'd0;
            i2s_lrck_r <= 1'b1;
            i2s_dout_r <= 1'b0;
        end
        else
        begin
            case (stc)
                S_WAIT_FRAME:
                begin
                    bit_count <= 4'd0;
                    sample_shift <= 16'd0;
                    i2s_dout_r <= 1'b0;
                end

                S_WAIT_SAMPLE:
                begin
                    if (i2s_tick_up)
                    begin
                        // 同拍完成握手或填入静音，下一次下降沿才输出 D15。
                        sample_shift <= in_valid ? audio_data : 16'd0;
                        bit_count <= 4'd0;
                    end
                end

                S_SEND_LEFT, S_SEND_RIGHT:
                begin
                    if (i2s_tick_down)
                    begin
                        i2s_dout_r <= sample_shift[15];
                        sample_shift <= {sample_shift[14:0], 1'b0};

                        if (bit_count == 4'd15)
                        begin
                            bit_count <= 4'd0;
                            // 发送本声道 D0 时切换 LRCK，下一次下降沿才发下声道 D15。
                            i2s_lrck_r <= (stc == S_SEND_LEFT);
                        end
                        else
                            bit_count <= bit_count + 1'b1;
                    end
                end

                default:
                begin
                    bit_count <= 4'd0;
                    sample_shift <= 16'd0;
                    i2s_dout_r <= 1'b0;
                end
            endcase

            if (smp_tick_up)
            begin
                i2s_lrck_r <= 1'b0;
                bit_count <= 4'd0;
                // dout 由发送分支处理上一帧右声道 D0，本拍为静音位 0。
            end
        end
    end

    assign sd_mode_r = 1'b1;
endmodule
