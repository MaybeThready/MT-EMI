/**
 * 正式工程的 UI 诊断顶层：复用正式 PLL、复位与节拍，直接例化 24 键／32 声部 UI。
 * 内部模拟扫描输入和音频忙闲反馈；全量输出经 1796 位串行采集与 CRC 接到板载 LED。
 * 此连接用于综合、布局布线和时序检查，不代表真实驱动／音频已接通，不输出声音。
 * WAVE_SELECT_STEPS=4 仅为测试配置；业务接口及参数默认值不变。
 * P16=50 MHz，U4=低有效复位，J14/N21=状态 LED；管脚、电压见 MT-EMI.cst。
 * TODO: 实物板版本、LED 极性、输入驱动和音频反馈协议仍需联调确认。
 */
`include "defines.vh"

module top
#(
    parameter STATUS_COUNTER_WIDTH = 25  // LED 刷新计数位宽，TB 缩小以检查心跳
)(
    input clk_core,
    input rst_n,
    output [1:0] status_led
);
    reg [31:0] crc_r;
    reg [STATUS_COUNTER_WIDTH-1:0] status_counter_r;
    reg heartbeat_r;
    reg checksum_status_r;
    wire crc_feedback;

    wire clk_sys;
    wire rst_sys_n;
    wire scan_tick_up;
    wire sample_tick;
    wire observed_serial;
    wire observed_valid;
    wire accepted_toggle;
    wire configuration_error;
    wire sample_overrun;
    reg [31:0] random_state_r;
    reg [27:0] source_frame_r;
    reg source_valid_r;
    wire source_ready;
    reg [12:0] tick_counter_r;
    wire audio_valid;
    wire audio_ready;
    wire [1795:0] packed_parameters;
    wire [1795:0] shift_register_r;
    wire [1795:0] shifted_parameters;
    wire prepare_capture;
    wire [28:0] capture_bank;
    genvar bank_index;
    reg [10:0] bits_remaining_r;
    reg observed_serial_r;
    reg observed_valid_r;
    reg accepted_toggle_r;
    reg observed_toggle_r;
    wire core_configuration_error;
    reg configuration_error_r;
    wire [15:0] key_velocity [23:0];
    wire [15:0] bend_value [0:0];
    wire [31:0] note_on;
    wire [31:0] note_off;
    wire [31:0] note_freq [31:0];
    wire [15:0] note_velocity [31:0];
    reg [31:0] simulated_busy_r;
    integer voice_index;
    genvar key_index;
    generate
        for (key_index=0;key_index<24;key_index=key_index+1)
        begin : keyboard_pressure_inputs
            assign key_velocity[key_index] = source_frame_r[15:0] ^ (16'd2039 * key_index);
        end
    endgenerate
    assign bend_value[0] = 16'h8000;
    wire [3:0] wavetable_0 [0:0];
    wire [3:0] wavetable_1 [0:0];
    wire [15:0] wavetable_interp [0:0];
    wire [15:0] init_phase [0:0];
    wire [19:0] attack_ticks [0:0];
    wire [19:0] decay_ticks [0:0];
    wire [15:0] sustain_level [0:0];
    wire [19:0] release_ticks [0:0];
    wire [15:0] master_volume;
    wire [15:0] reverb_mix;
    wire [15:0] delay_mix;
    wire [15:0] distortion_mix;
    wire [15:0] chorus_mix;
    sys_clocker sys_clocker_u (
        .clk_core(clk_core), .rst_n(rst_n),
        .clk_sys(clk_sys), .rst_sys_n(rst_sys_n)
    );

    sys_ticker sys_ticker_u (
        .clk_sys(clk_sys), .rst_n(rst_sys_n),
        .i2s_tick_up(), .i2s_tick_down(),
        .smp_tick_up(sample_tick), .smp_tick_down(),
        .scan_tick_up(scan_tick_up), .scan_tick_down()
    );

    // 单槽弹性发送源：仅在空闲或本拍成功接收时更新。
    // 这是验证激励，不能替代真实输入驱动。
    always @(posedge clk_sys or negedge rst_sys_n)
    begin
        if (!rst_sys_n)
        begin
            random_state_r <= 32'h3A51_C7E9;
            source_frame_r <= 28'd0;
            source_valid_r <= 1'b0;
            tick_counter_r <= 13'd0;
            simulated_busy_r <= 32'd0;
        end
        else
        begin
            random_state_r <= {random_state_r[30:0], random_state_r[31] ^ random_state_r[21] ^ random_state_r[1] ^ random_state_r[0]};
            tick_counter_r <= tick_counter_r + 13'd1;
            // 仅验证反馈接线和逻辑存活，真实包络仍待音频负责人实现。
            if (audio_valid && audio_ready)
            begin
                for (voice_index = 0; voice_index < 32; voice_index = voice_index + 1)
                begin
                    if (note_on[voice_index]) simulated_busy_r[voice_index] <= 1'b1;
                    else if (note_off[voice_index]) simulated_busy_r[voice_index] <= 1'b0;
                end
            end
            if (source_valid_r && source_ready)
                source_valid_r <= 1'b0;
            // 模拟驱动在扫描节拍准备一组数据；背压时保持未交付数据。
            if (scan_tick_up && (!source_valid_r || source_ready))
            begin
                source_frame_r <= random_state_r[27:0];
                source_valid_r <= 1'b1;
            end
        end
    end
    // IF-OBSERVE-02：先预约、下一沿整帧握手并采集；发送端须保持 valid 和载荷。
    // 接收端可以等待 valid；UI 发送端仍不以 ready 为产生 valid 的条件。
    assign prepare_capture = audio_valid && !capture_bank[0] &&
        (bits_remaining_r == 11'd0) && (tick_counter_r[5:0] < 6'd8);
    assign audio_ready = capture_bank[0];
    assign shifted_parameters = {1'b0, shift_register_r[1795:1]};
    generate
        for (bank_index = 0; bank_index < 29; bank_index = bank_index + 1)
        begin : observation_banks
            localparam BANK_WIDTH = (bank_index == 28) ? 4 : 64;
            // 保留 29 个本地采集寄存器，防止等价合并后再次形成千级扇出。
            reg capture_r /* synthesis syn_preserve = 1 */;
            reg [BANK_WIDTH-1:0] data_r;
            assign capture_bank[bank_index] = capture_r;
            assign shift_register_r[64 * bank_index +: BANK_WIDTH] = data_r;
            always @(posedge clk_sys or negedge rst_sys_n)
            begin
                if (!rst_sys_n)
                begin
                    capture_r <= 1'b0;
                    data_r <= {BANK_WIDTH{1'b0}};
                end
                else
                begin
                    capture_r <= prepare_capture;
                    if (capture_r)
                        data_r <= packed_parameters[64 * bank_index +: BANK_WIDTH];
                    else
                        // 无效期间也允许移位；仅 observed_valid 确认的 1796 位有效。
                        data_r <= shifted_parameters[64 * bank_index +: BANK_WIDTH];
                end
            end
        end
    endgenerate
    user_interface #(
        .WAVE_SELECT_STEPS(4), .SMP_TICK_FREQ(`SMP_TICK_FREQ)
    ) user_interface_u (
        .clk_sys(clk_sys),
        .rst_n(rst_sys_n),
        .scan_tick_up(scan_tick_up),
        .key_states(source_frame_r[23:0]),
        .key_velocity(key_velocity),
        .knob_states(source_frame_r[7:0]),
        .knob_dirs(source_frame_r[15:8]),
        .knob_pressed(source_frame_r[23:16]),
        .bend_value(bend_value),
        .note_busy(simulated_busy_r),
        .note_on(note_on),
        .note_off(note_off),
        .note_freq(note_freq),
        .note_velocity(note_velocity),
        .in_valid(source_valid_r),
        .in_ready(source_ready),
        .out_valid(audio_valid),
        .out_ready(audio_ready),
        .button_states(source_frame_r[27:24]),
        .smp_tick_up(sample_tick),
        .configuration_error(core_configuration_error),
        .sample_overrun(sample_overrun),
        .wavetable_0(wavetable_0),
        .wavetable_1(wavetable_1),
        .wavetable_interp(wavetable_interp),
        .init_phase(init_phase),
        .attack_ticks(attack_ticks),
        .decay_ticks(decay_ticks),
        .sustain_level(sustain_level),
        .release_ticks(release_ticks),
        .master_volume(master_volume),
        .reverb_mix(reverb_mix),
        .delay_mix(delay_mix),
        .distortion_mix(distortion_mix),
        .chorus_mix(chorus_mix)
    );

    assign packed_parameters = {note_velocity[31], note_velocity[30], note_velocity[29], note_velocity[28], note_velocity[27], note_velocity[26], note_velocity[25], note_velocity[24], note_velocity[23], note_velocity[22], note_velocity[21], note_velocity[20], note_velocity[19], note_velocity[18], note_velocity[17], note_velocity[16], note_velocity[15], note_velocity[14], note_velocity[13], note_velocity[12], note_velocity[11], note_velocity[10], note_velocity[9], note_velocity[8], note_velocity[7], note_velocity[6], note_velocity[5], note_velocity[4], note_velocity[3], note_velocity[2], note_velocity[1], note_velocity[0], note_freq[31], note_freq[30], note_freq[29], note_freq[28], note_freq[27], note_freq[26], note_freq[25], note_freq[24], note_freq[23], note_freq[22], note_freq[21], note_freq[20], note_freq[19], note_freq[18], note_freq[17], note_freq[16], note_freq[15], note_freq[14], note_freq[13], note_freq[12], note_freq[11], note_freq[10], note_freq[9], note_freq[8], note_freq[7], note_freq[6], note_freq[5], note_freq[4], note_freq[3], note_freq[2], note_freq[1], note_freq[0], note_off, note_on, chorus_mix, distortion_mix, delay_mix, reverb_mix, master_volume, release_ticks[0], sustain_level[0], decay_ticks[0], attack_ticks[0], init_phase[0], wavetable_interp[0], wavetable_1[0], wavetable_0[0]};
    always @(posedge clk_sys or negedge rst_sys_n)
    begin
        if (!rst_sys_n)
        begin
            bits_remaining_r <= 11'd0;
            observed_serial_r <= 1'b0;
            observed_valid_r <= 1'b0;
            accepted_toggle_r <= 1'b0;
            observed_toggle_r <= 1'b0;
            configuration_error_r <= 1'b0;
        end
        else
        begin
            observed_valid_r <= 1'b0;
            // 仅寄存诊断引脚，不改变实际 UI 错误信号。
            configuration_error_r <= core_configuration_error;
            // 独立输出寄存器无翻转反馈，便于使用 IOB 寄存器。
            observed_toggle_r <= accepted_toggle_r;
            if (audio_valid && audio_ready)
            begin
                bits_remaining_r <= 11'd1796;
                accepted_toggle_r <= ~accepted_toggle_r;
            end
            else if (bits_remaining_r != 11'd0)
            begin
                observed_serial_r <= shift_register_r[0];
                observed_valid_r <= 1'b1;
                bits_remaining_r <= bits_remaining_r - 11'd1;
            end
        end
    end
    assign observed_serial = observed_serial_r;
    assign observed_valid = observed_valid_r;
    assign accepted_toggle = observed_toggle_r;
    assign configuration_error = configuration_error_r;

    assign crc_feedback = crc_r[31] ^ observed_serial;
    assign status_led[0] = heartbeat_r;
    assign status_led[1] = configuration_error || sample_overrun || checksum_status_r;

    always @(posedge clk_sys or negedge rst_sys_n)
    begin
        if (!rst_sys_n)
        begin
            crc_r <= 32'hffffffff;
            status_counter_r <= {STATUS_COUNTER_WIDTH{1'b0}};
            heartbeat_r <= 1'b0;
            checksum_status_r <= 1'b0;
        end
        else
        begin
            // CRC-32 多项式，只用于保留全参数可观察性，不作为黄金结果比较器。
            if (observed_valid)
                crc_r <= {crc_r[30:0],1'b0} ^ (crc_feedback ? 32'h04c11db7 : 32'd0);
            status_counter_r <= status_counter_r + {{(STATUS_COUNTER_WIDTH-1){1'b0}},1'b1};
            if (&status_counter_r)
            begin
                heartbeat_r <= ~heartbeat_r;
                checksum_status_r <= crc_r[0];
            end
        end
    end
endmodule
