/**
 * 混音模块时序检查顶层。
 * 仅保留系统时钟、混音模块和测试数据寄存器，以便定位混音 RAM 与效果器的关键路径。
 * status_led 用于保留音频输出逻辑；本顶层不用于正式音频输出。
 */
module top
(
    input clk_core,
    input rst_n,  // K16：低有效系统复位，不作为 UI 菜单按钮
    output flash_cs_n,
    output flash_clk,
    output flash_mosi,
    input flash_miso,
    output flash_wp_n,
    output flash_hold_n,
    output [1:0] status_led,
    output [1:0] saved_value_led,  // 低有效，LED2/L20、LED3/M25
    output [1:0] clock_status_led,
    output lcd_clk,
    output lcd_en,
    output [5:0] lcd_r,
    output [5:0] lcd_g,
    output [5:0] lcd_b,
    output lcd_bl,
    output lcd_hs_n,
    output lcd_vs_n
);
    localparam MAX_POLYPHONY = 32;

    // 使用非零效果参数，让综合保留效果器及共享 RAM 的完整数据路径。
    localparam [15:0] REVERB_MIX = 16'h5000;
    localparam [15:0] REVERB_FEEDBACK = 16'ha000;
    localparam [15:0] REVERB_DAMPING = 16'h3000;
    localparam [15:0] DELAY_MIX = 16'h4000;
    localparam [15:0] DELAY_TIME = 16'd12000;
    localparam [15:0] DELAY_FEEDBACK = 16'h6000;
    localparam [15:0] DISTORTION_MIX = 16'h1800;
    localparam [15:0] DISTORTION_GAIN = 16'h2800;
    localparam [15:0] DISTORTION_TONE = 16'hb000;
    localparam [15:0] CHORUS_MIX = 16'h5000;
    localparam [15:0] CHORUS_RATE = 16'h3000;
    localparam [7:0] CHORUS_DEPTH = 8'd48;
    localparam [15:0] BALANCE_VOLUME = 16'h8000;
    localparam [15:0] MASTER_VOLUME = 16'h8000;

    wire clk_sys, rst_sys_n;
    sys_clocker sys_clocker_u (
        .clk_core(clk_core), .rst_n(rst_n),
        .clk_sys(clk_sys), .rst_sys_n(rst_sys_n)
    );

    // 每次混音模块接收数据后更新输入，持续驱动完整效果器链。
    reg signed [15+$clog2(MAX_POLYPHONY):0] audio_stimulus_r;
    reg signed [15:0] audio_observe_r;
    reg [15:0] sample_count_r;
    wire signed [15:0] audio_out;
    wire in_ready, out_valid;

    mixer #(.MAX_POLYPHONY(MAX_POLYPHONY)) mixer_u (
        .clk_sys(clk_sys), .rst_n(rst_sys_n),
        .smp_tick_up(1'b0),
        .audio_in(audio_stimulus_r),
        .reverb_mix(REVERB_MIX),
        .reverb_feedback(REVERB_FEEDBACK),
        .reverb_damping(REVERB_DAMPING),
        .delay_mix(DELAY_MIX),
        .delay_time(DELAY_TIME),
        .delay_feedback(DELAY_FEEDBACK),
        .distortion_mix(DISTORTION_MIX),
        .distortion_gain(DISTORTION_GAIN),
        .distortion_tone(DISTORTION_TONE),
        .chorus_mix(CHORUS_MIX),
        .chorus_rate(CHORUS_RATE),
        .chorus_depth(CHORUS_DEPTH),
        .balance_volume(BALANCE_VOLUME),
        .master_volume(MASTER_VOLUME),
        .audio_out(audio_out),
        .out_ready(1'b1),
        .in_valid(1'b1),
        .out_valid(out_valid),
        .in_ready(in_ready)
    );

    always @(posedge clk_sys or negedge rst_sys_n)
    begin
        if (!rst_sys_n)
        begin
            audio_stimulus_r <= '0;
            audio_observe_r <= '0;
            sample_count_r <= 16'd0;
        end
        else
        begin
            if (in_ready)
            begin
                audio_stimulus_r <= audio_stimulus_r + 21'sd977;
                sample_count_r <= sample_count_r + 1'b1;
            end
            if (out_valid)
                audio_observe_r <= audio_out;
        end
    end

    assign status_led[0] = sample_count_r[14] ^ data_a ^ data_b;
    assign status_led[1] = ^audio_observe_r;

    // 保留现有物理约束的引脚；时序测试不驱动键盘和 I2S。
    assign load_n = 1'b1;
    assign key_clk = 1'b0;
    assign i2s_bclk = 1'b0;
    assign i2s_lrck = 1'b0;
    assign i2s_dout = 1'b0;
    assign sd_mode_n = 1'b1;
endmodule
