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
 * in_valid / in_ready: 单槽待播缓冲。空槽随时接收一个采样；帧起点
 * 消费旧采样并允许同拍接收下一个。没有待播采样时发送静音。
 * 同拍空槽输入直接用于本帧；上游应保持 valid 和数据直到握手。
 * audio_out_lcd / out_valid_lcd / out_ready_lcd: 当前帧实际发送的 PCM
 * 镜像。LCD 背压时保持旧值；若下一帧到来仍未读走，则跳过该帧的显示采样。
 * LCD 不会阻塞 I2S，也不会改变上游的 in_ready。
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
    output signed [15:0] audio_out_lcd,
    input out_ready_lcd,
    output out_valid_lcd,
    output i2s_bclk,
    output i2s_lrck,
    output i2s_dout,
    output sd_mode_n,
    output in_ready
);
    localparam [1:0]
        S_WAIT_FRAME = 2'd0,
        S_SEND_LEFT = 2'd1,
        S_SEND_RIGHT = 2'd2;

    wire [1:0] stc;
    reg [1:0] stn;
    reg [3:0] bit_count;      // 当前声道已发送位数
    reg [15:0] sample_shift;
    reg signed [15:0] pending_sample_r, lcd_sample_r;
    reg pending_valid_r, lcd_valid_r;
    reg i2s_bclk_r;
    reg i2s_lrck_r;
    reg i2s_dout_r;

    assign i2s_bclk = i2s_bclk_r;
    assign i2s_lrck = i2s_lrck_r;
    assign i2s_dout = i2s_dout_r;
    assign in_ready = rst_n && (!pending_valid_r || smp_tick_up);
    assign audio_out_lcd = lcd_sample_r;
    assign out_valid_lcd = lcd_valid_r;
    wire input_fire = in_valid && in_ready;
    wire signed [15:0] frame_sample = pending_valid_r ? pending_sample_r :
                                      (input_fire ? audio_data : 16'sd0);

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
            stn = S_SEND_LEFT;
        else
        begin
            case (stc)
                S_WAIT_FRAME: stn = S_WAIT_FRAME;
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

    // 输入缓冲与 LCD 镜像各自独立握手。
    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            pending_sample_r <= 16'sd0;
            pending_valid_r <= 1'b0;
            lcd_sample_r <= 16'sd0;
            lcd_valid_r <= 1'b0;
        end
        else
        begin
            if (smp_tick_up)
            begin
                // 旧样本送本帧；同拍新样本留给下一帧。
                pending_valid_r <= pending_valid_r && input_fire;
                if (pending_valid_r && input_fire)
                    pending_sample_r <= audio_data;
                if (!lcd_valid_r || out_ready_lcd)
                begin
                    lcd_sample_r <= frame_sample;
                    lcd_valid_r <= 1'b1;
                end
            end
            else
            begin
                if (input_fire)
                begin
                    pending_sample_r <= audio_data;
                    pending_valid_r <= 1'b1;
                end
                if (lcd_valid_r && out_ready_lcd)
                    lcd_valid_r <= 1'b0;
            end
        end
    end

    // 帧起点装载待播采样，随后只在 BCLK 下降沿更新串行数据。
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
                sample_shift <= frame_sample;
            end
        end
    end

    assign sd_mode_n = 1'b1;
endmodule
