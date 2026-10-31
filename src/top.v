/**
 * 通道机架时序检查顶层
 * 采用正式时钟和采样节拍，以内部测试数据驱动 32 声部机架。
 * LED 仅用于保留音频计算路径，不代表正式音频输出接口。
 */
`include "defines.vh"

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

    wire clk_sys, rst_sys_n, smp_tick_up;
    sys_clocker sys_clocker_u (
        .clk_core(clk_core),
        .rst_n(rst_n),
        .clk_sys(clk_sys),
        .rst_sys_n(rst_sys_n)
    );

    sys_ticker sys_ticker_u (
        .clk_sys(clk_sys),
        .rst_n(rst_sys_n),
        .i2s_tick_up(),
        .i2s_tick_down(),
        .smp_tick_up(smp_tick_up),
        .smp_tick_down(),
        .scan_tick_up(),
        .scan_tick_down()
    );

    reg [15:0] sample_count_r;
    wire [MAX_POLYPHONY-1:0] note_on, note_off, note_busy;
    wire [31:0] note_freq [MAX_POLYPHONY-1:0];
    wire [15:0] note_velocity [MAX_POLYPHONY-1:0];
    wire signed [15+$clog2(MAX_POLYPHONY):0] audio_out;
    wire in_ready, out_valid;

    genvar voice_index;
    generate
        for (voice_index = 0; voice_index < MAX_POLYPHONY; voice_index = voice_index + 1)
        begin : voice_stimulus
            assign note_on[voice_index] = sample_count_r[8:0] == voice_index;
            assign note_off[voice_index] = sample_count_r[8:0] == voice_index + 128;
            assign note_freq[voice_index] = 32'd14_417_920 + voice_index * 32'd655_360
                                          + {12'd0, sample_count_r[3:0], 16'd0};
            assign note_velocity[voice_index] = 16'h8000 + {sample_count_r[5:0], 8'd0};
        end
    endgenerate

    channel_rack #(
        .MAX_POLYPHONY(MAX_POLYPHONY)
    ) channel_rack_u (
        .clk_sys(clk_sys),
        .rst_n(rst_sys_n),
        .smp_tick_up(smp_tick_up),
        .note_on(note_on),
        .note_off(note_off),
        .note_busy(note_busy),
        .note_freq(note_freq),
        .note_velocity(note_velocity),
        .init_phase(16'd0),
        .attack_ticks(20'd4),
        .decay_ticks(20'd8),
        .sustain_level(16'hc000),
        .release_ticks(20'd16),
        .wavetable_0({2'd0, sample_count_r[7:6]}),
        .wavetable_1({2'd0, sample_count_r[9:8]}),
        .wavetable_interp({sample_count_r[7:0], 8'd0}),
        .audio_out(audio_out),
        .out_ready(1'b1),
        .in_valid(1'b1),
        .out_valid(out_valid),
        .in_ready(in_ready)
    );

    reg [15+$clog2(MAX_POLYPHONY):0] audio_observe_r;
    always @(posedge clk_sys or negedge rst_sys_n)
    begin
        if (!rst_sys_n)
        begin
            sample_count_r <= 16'd0;
            audio_observe_r <= '0;
        end
        else
        begin
            if (in_ready)
                sample_count_r <= sample_count_r + 1'b1;
            if (out_valid)
                audio_observe_r <= audio_out;
        end
    end

    assign status_led[0] = sample_count_r[14];
    assign status_led[1] = ^audio_observe_r ^ ^note_busy;
endmodule
