/**
 * 正式工程的 UI 诊断顶层 v3：复用正式 PLL、复位与节拍，直接例化 24 键／32 声部 UI。
 * v3版本修改：接入 U7 音色 Flash；四个菜单按钮改为底板真实按键并同步消抖。
 * v2版本修改：弯音随输入帧交替覆盖中心、两端及随机位置，背压时保持整帧。
 * 内部模拟扫描输入和音频忙闲反馈；全量输出经 1812 位串行采集与 CRC 接到板载 LED。
 * 此连接用于综合、布局布线和时序检查，不代表真实驱动／音频已接通，不输出声音。
 * WAVE_SELECT_STEPS=4 仅为测试配置；业务接口及参数默认值不变。
 * P16=50 MHz，U4=高有效 SW5 按键（按下=1，松开=0），内部转换为 rst_n。
 * NOTE: 4072 核心板原理图第 7 页 R35/SW5/R37/C167；旧引脚表的低有效备注有误。
 * TODO: 实物板版本、LED 极性、输入驱动和音频反馈协议仍需联调确认。
 */
`include "defines.vh"

module top
#(
    parameter STATUS_COUNTER_WIDTH = 25,  // 原诊断心跳计数位宽
    parameter HEARTBEAT_BIT = 14,  // S1 帧计数心跳位，0..15；TB 缩小以加速观察
    parameter BUTTON_DEBOUNCE_CYCLES = 2000000,  // 约 20 ms，单位为 clk_sys 周期
    parameter FLASH_HALF_PERIOD_CYCLES = 50,  // 约 0.982 MHz SPI，修改时同步核对 SDC 预算
    parameter FLASH_POWER_UP_CYCLES = 1000000,
    parameter FLASH_BOARD_TEST = 0  // 1: S2/3编辑灯值、S0保存/S1读取；0: 原UI菜单联调
)(
    input clk_core,
    input reset_button,  // SW5/U4 physical level: pressed high, released low
    input [3:0] ui_button_n,  // 底板 S0..S3：低有效，对应 UI B1..B4
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
    reg [31:0] crc_r;
    reg [STATUS_COUNTER_WIDTH-1:0] status_counter_r;
    reg heartbeat_r;
    reg [15:0] frame_count_r;
    reg checksum_status_r;
    wire crc_feedback;

    wire clk_sys;
    wire rst_n;
    assign rst_n = ~reset_button;
    wire rst_sys_n;
    localparam BUTTON_COUNTER_WIDTH = (BUTTON_DEBOUNCE_CYCLES > 1) ? $clog2(BUTTON_DEBOUNCE_CYCLES) : 1;
    wire [3:0] button_sync;
    reg [3:0] button_pressed_r;
    genvar button_index;
    wire storage_out_valid, storage_out_ready, storage_out_write;
    wire [3:0] storage_out_slot;
    wire [511:0] storage_out_data;
    wire storage_in_valid, storage_in_ready;
    wire [2:0] storage_in_status;
    wire [511:0] storage_in_data;
    wire storage_catalog_valid;
    wire [15:0] storage_slot_present;
    wire [23:0] storage_jedec_id;
    wire ui_storage_valid, ui_storage_write, ui_storage_ready;
    wire [3:0] ui_storage_slot;
    wire [511:0] ui_storage_data;
    wire test_valid, test_write, test_ready;
    wire [3:0] test_slot;
    wire [511:0] test_data;
    wire [1:0] test_led_on;
    wire [1:0] test_value_led_on;
    assign saved_value_led = FLASH_BOARD_TEST ? ~test_value_led_on : 2'b11;
    wire [2:0] flash_test_status, flash_test_driver_status;
    assign storage_out_valid = FLASH_BOARD_TEST ? test_valid : ui_storage_valid;
    assign storage_out_write = FLASH_BOARD_TEST ? test_write : ui_storage_write;
    assign storage_out_slot = FLASH_BOARD_TEST ? test_slot : ui_storage_slot;
    assign storage_out_data = FLASH_BOARD_TEST ? test_data : ui_storage_data;
    assign storage_in_ready = FLASH_BOARD_TEST ? test_ready : ui_storage_ready;

    flash_board_test flash_board_test_u (
        .clk_sys(clk_sys), .rst_n(rst_sys_n),
        .buttons(FLASH_BOARD_TEST ? button_pressed_r : 4'd0),
        .catalog_valid(storage_catalog_valid), .jedec_id(storage_jedec_id),
        .request_valid(test_valid), .request_ready(FLASH_BOARD_TEST && storage_out_ready),
        .request_write(test_write), .request_slot(test_slot), .request_data(test_data),
        .response_valid(FLASH_BOARD_TEST && storage_in_valid), .response_ready(test_ready),
        .response_status(storage_in_status), .response_data(storage_in_data),
        .status(flash_test_status), .driver_status(flash_test_driver_status), .led_on(test_led_on),
        .value_led_on(test_value_led_on)
    );

    // 最新 4071f Rev1.5 第 15 页：S0..S3 均上拉、按下接地。
    // 独立两级同步后连续稳定约 20 ms 才改变状态；随源帧锁存以满足背压。
    signal_sync #(.W(4), .INITIAL_VALUE(4'b1111)) button_sync_u (
        .clk(clk_sys), .rst_n(rst_sys_n), .signal_in(ui_button_n), .signal_out(button_sync)
    );
    generate
        for (button_index = 0; button_index < 4; button_index = button_index + 1)
        begin : button_filters
            reg [BUTTON_COUNTER_WIDTH-1:0] counter_r;
            always @(posedge clk_sys or negedge rst_sys_n)
            begin
                if (!rst_sys_n)
                begin
                    counter_r <= {BUTTON_COUNTER_WIDTH{1'b0}};
                    button_pressed_r[button_index] <= 1'b0;
                end
                else if ((!button_sync[button_index]) == button_pressed_r[button_index])
                    counter_r <= {BUTTON_COUNTER_WIDTH{1'b0}};
                else if (counter_r == BUTTON_DEBOUNCE_CYCLES - 1)
                begin
                    counter_r <= {BUTTON_COUNTER_WIDTH{1'b0}};
                    button_pressed_r[button_index] <= !button_sync[button_index];
                end
                else counter_r <= counter_r + 1'b1;
            end
        end
    endgenerate

    // Driver与UI平级例化；保持此层级以沿用SPI约束，不在UI内重复实例化。
    preset_storage_driver #(
        .HALF_PERIOD_CYCLES(FLASH_HALF_PERIOD_CYCLES), .POWER_UP_CYCLES(FLASH_POWER_UP_CYCLES)
    ) preset_storage_driver_u (
        .clk_sys(clk_sys), .rst_n(rst_sys_n),
        .in_valid(storage_out_valid), .in_ready(storage_out_ready), .in_write(storage_out_write),
        .in_slot(storage_out_slot), .in_data(storage_out_data),
        .out_valid(storage_in_valid), .out_ready(storage_in_ready),
        .out_status(storage_in_status), .out_data(storage_in_data),
        .catalog_valid(storage_catalog_valid), .slot_present(storage_slot_present),
        .jedec_id(storage_jedec_id), .flash_cs_n(flash_cs_n), .flash_clk(flash_clk),
        .flash_mosi(flash_mosi), .flash_miso(flash_miso), .flash_wp_n(flash_wp_n), .flash_hold_n(flash_hold_n)
    );
    wire [1:0] clock_status;
    // Active-low: LED1/R26 independent heartbeat, LED5/N23 sticky fault.
    assign clock_status_led = ~clock_status;
    wire scan_tick_up;
    wire sample_tick;
    wire observed_serial;
    wire observed_valid;
    wire accepted_toggle;
    wire configuration_error;
    wire sample_overrun;
    reg [31:0] random_state_r;
    reg [27:0] source_frame_r;
    reg [15:0] source_bend_r;
    reg [1:0] bend_test_index_r;
    reg source_valid_r;
    wire source_ready;
    reg [12:0] tick_counter_r;
    wire audio_valid;
    wire audio_ready;
    wire [1811:0] packed_parameters;
    wire [1811:0] shift_register_r;
    wire [1811:0] shifted_parameters;
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
    assign bend_value[0] = source_bend_r;
    wire [3:0] wavetable_0 [0:0];
    wire [3:0] wavetable_1 [0:0];
    wire [15:0] wavetable_interp [0:0];
    wire [15:0] init_phase [0:0];
    wire [19:0] attack_ticks [0:0];
    wire [19:0] decay_ticks [0:0];
    wire [15:0] sustain_level [0:0];
    wire [19:0] release_ticks [0:0];
    wire [15:0] master_volume;
    wire [15:0] balance_volume;  // 音色增益参与诊断采集，后续接音频端
    wire [15:0] reverb_mix;
    wire [15:0] delay_mix;
    wire [15:0] distortion_mix;
    wire [15:0] chorus_mix;
    sys_clocker sys_clocker_u (
        .clk_core(clk_core), .rst_n(rst_n),
        .clk_sys(clk_sys), .rst_sys_n(rst_sys_n), .clock_status(clock_status)
    );

    // Same two-LED interface and 16-bit frame-count heartbeat as S1 test tops.
    // This LCD diagnostic has no I2S driver; count the existing sample tick.
    // At nominal 48 kHz, bit 14 blinks at 48000 / 32768 = 1.465 Hz.
    always @(posedge clk_sys or negedge rst_sys_n)
    begin
        if (!rst_sys_n)
            frame_count_r <= 16'd0;
        else if (sample_tick)
            frame_count_r <= frame_count_r + 16'd1;
    end

    // LCD bring-up only: full UI diagnostic structure remains active.
    lcd_driver lcd_driver_u (
        .clk(clk_sys), .rst_n(rst_sys_n),
        .lcd_clk(lcd_clk), .lcd_en(lcd_en),
        .lcd_r(lcd_r), .lcd_g(lcd_g), .lcd_b(lcd_b),
        .lcd_bl(lcd_bl), .lcd_hs_n(lcd_hs_n), .lcd_vs_n(lcd_vs_n)
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
            source_bend_r <= 16'h8000;
            bend_test_index_r <= 2'd0;
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
                // 菜单按钮必须来自真实按键，不能用随机数触发持久化写入。
                source_frame_r <= {button_pressed_r, random_state_r[23:0]};
                // 与键盘帧一起锁存，不能直接接到每拍变化的随机数。
                case (bend_test_index_r)
                    2'd0: source_bend_r <= 16'h8000;
                    2'd1: source_bend_r <= 16'h0000;
                    2'd2: source_bend_r <= 16'hffff;
                    default: source_bend_r <= random_state_r[31:16];
                endcase
                bend_test_index_r <= bend_test_index_r + 2'd1;
                source_valid_r <= 1'b1;
            end
        end
    end
    // IF-OBSERVE-02：先预约、下一沿整帧握手并采集；发送端须保持 valid 和载荷。
    // 接收端可以等待 valid；UI 发送端仍不以 ready 为产生 valid 的条件。
    assign prepare_capture = audio_valid && !capture_bank[0] &&
        (bits_remaining_r == 11'd0) && (tick_counter_r[5:0] < 6'd8);
    assign audio_ready = capture_bank[0];
    assign shifted_parameters = {1'b0, shift_register_r[1811:1]};
    generate
        for (bank_index = 0; bank_index < 29; bank_index = bank_index + 1)
        begin : observation_banks
            localparam BANK_WIDTH = (bank_index == 28) ? 20 : 64;
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
                        // 无效期间也允许移位；仅 observed_valid 确认的 1812 位有效。
                        data_r <= shifted_parameters[64 * bank_index +: BANK_WIDTH];
                end
            end
        end
    endgenerate
    user_interface #(
        .WAVE_SELECT_STEPS(4), .SMP_TICK_FREQ(`SMP_TICK_FREQ)
    ) user_interface_u (
        // 板级测试时隔离 UI 存储请求，避免菜单和测试同时访问 Flash。
        .storage_out_valid(ui_storage_valid),
        .storage_out_ready(!FLASH_BOARD_TEST && storage_out_ready),
        .storage_out_write(ui_storage_write),
        .storage_out_slot(ui_storage_slot),
        .storage_out_data(ui_storage_data),
        .storage_in_valid(!FLASH_BOARD_TEST && storage_in_valid),
        .storage_in_ready(ui_storage_ready),
        .storage_in_status(storage_in_status),
        .storage_in_data(storage_in_data),
        .menu_page(),
        .menu_selection(),
        .menu_slot(),
        .menu_save(),
        .menu_result_status(),
        .storage_catalog_valid(storage_catalog_valid),
        .storage_slot_present(storage_slot_present),
        .menu_slot_known(),
        .menu_slot_present(),
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
        .master_volume(master_volume), .balance_volume(balance_volume),
        .reverb_mix(reverb_mix),
        .delay_mix(delay_mix),
        .distortion_mix(distortion_mix),
        .chorus_mix(chorus_mix)
    );

    assign packed_parameters = {note_velocity[31], note_velocity[30], note_velocity[29], note_velocity[28], note_velocity[27], note_velocity[26], note_velocity[25], note_velocity[24], note_velocity[23], note_velocity[22], note_velocity[21], note_velocity[20], note_velocity[19], note_velocity[18], note_velocity[17], note_velocity[16], note_velocity[15], note_velocity[14], note_velocity[13], note_velocity[12], note_velocity[11], note_velocity[10], note_velocity[9], note_velocity[8], note_velocity[7], note_velocity[6], note_velocity[5], note_velocity[4], note_velocity[3], note_velocity[2], note_velocity[1], note_velocity[0], note_freq[31], note_freq[30], note_freq[29], note_freq[28], note_freq[27], note_freq[26], note_freq[25], note_freq[24], note_freq[23], note_freq[22], note_freq[21], note_freq[20], note_freq[19], note_freq[18], note_freq[17], note_freq[16], note_freq[15], note_freq[14], note_freq[13], note_freq[12], note_freq[11], note_freq[10], note_freq[9], note_freq[8], note_freq[7], note_freq[6], note_freq[5], note_freq[4], note_freq[3], note_freq[2], note_freq[1], note_freq[0], note_off, note_on, chorus_mix, distortion_mix, delay_mix, reverb_mix, balance_volume, master_volume, release_ticks[0], sustain_level[0], decay_ticks[0], attack_ticks[0], init_phase[0], wavetable_interp[0], wavetable_1[0], wavetable_0[0]};
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
                bits_remaining_r <= 11'd1812;
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
    // S3 按住时显示原 UI 诊断，保留完整诊断数据链的可观察性。
    assign status_led[0] = FLASH_BOARD_TEST
        ? ~test_led_on[0] : frame_count_r[HEARTBEAT_BIT];
    assign status_led[1] = FLASH_BOARD_TEST
        ? ~test_led_on[1] : (configuration_error || sample_overrun || checksum_status_r);

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
