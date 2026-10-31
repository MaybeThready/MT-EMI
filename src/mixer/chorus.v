/**
 * 单声部调制延迟合唱：三角 LFO 调节 256～约 511 个采样的延迟，
 * 在相邻历史采样间线性插值，然后与当前输入干湿混合。
 * 音频采样和 RAM 历史均为 24 位 SQ9.15；内部求差、求和加宽并饱和。
 * 本模块独占从 RAM_BASE_ADDR 开始的 1024 个 24 位字。
 */

/**
 * clk_sys: 系统时钟；rst_n: 低有效异步复位，只清控制状态，不清外部 RAM
 * audio_in/audio_out: 24 位有符号 SQ9.15 效果器链采样
 * chorus_mix: 干湿比例，UQ0.16；0 为纯干声，16'hffff 近似纯湿声
 * chorus_rate: 三角 LFO 频率，UQ2.14 Hz；0 时相位保持
 * chorus_depth: 延迟调制深度，单位为 smp_tick；0 时固定延迟 256 个采样
 * in_valid/in_ready、out_valid/out_ready: 每个采样各进行一次 valid-ready 握手
 * ram_read_en/ram_read_addr: 向共享 RAM 发起同步读取；预留两拍供 mixer 寄存地址和数据
 * ram_write_en/ram_write_addr/ram_write_data: 在时钟上升沿写入当前采样
 * ram_read_data/ram_write_data: 外部 81920 x 24 SDP RAM 的数据端口，
 *                               两端口均接 clk_sys，输出使能常开
 * RAM_BASE_ADDR: 合唱专用区起始地址，须满足 RAM_BASE_ADDR + 1024 <= 81920；
 *                默认 73728，与混响 0～7493、延迟 8192～73727 不重叠
 * 每次已接受输入对应一个连续音频采样；LFO 每接受一个采样推进一次。
 */
module chorus
#(
    parameter SAMPLE_RATE = 48000,
    parameter [16:0] RAM_BASE_ADDR = 17'd73728
)(
    input clk_sys,
    input rst_n,
    input signed [23:0] audio_in,
    input [15:0] chorus_mix,
    input [15:0] chorus_rate,
    input [7:0] chorus_depth,
    output signed [23:0] audio_out,
    input out_ready,
    input in_valid,
    output out_valid,
    output in_ready,
    output ram_read_en,
    output [16:0] ram_read_addr,
    input signed [23:0] ram_read_data,
    output ram_write_en,
    output [16:0] ram_write_addr,
    output signed [23:0] ram_write_data
);
    // phase_step ≈ rate(UQ2.14) * 2^32 / (SAMPLE_RATE * 2^14)。
    // 先用常量乘法保留 16 位附加精度，舍去低 16 位后每采样加到相位。
    localparam [18:0] PHASE_STEP_K =
        (64'd281474976710656 + SAMPLE_RATE * 64'd8192) /
        (SAMPLE_RATE * 64'd16384);

    localparam WF_RECV = 5'd0, LFO_CALC = 5'd1,
               ADDR_CALC = 5'd2, RAM_READ_NEW = 5'd3,
               RAM_WAIT_NEW_1 = 5'd4, RAM_WAIT_NEW_2 = 5'd5,
               RAM_WAIT_NEW = 5'd6, RAM_READ_OLD = 5'd7,
               RAM_WAIT_OLD_1 = 5'd8, RAM_WAIT_OLD_2 = 5'd9,
               RAM_WAIT_OLD = 5'd10, RAM_WRITE = 5'd11,
               INTERP_SETUP = 5'd12, INTERP_MULT = 5'd13,
               INTERP_APPLY = 5'd14, MIX_SETUP = 5'd15,
               MIX_MULT = 5'd16, MIX_APPLY = 5'd17,
               WF_SEND = 5'd18;

    wire [4:0] stc;
    reg [4:0] stn;
    fsm #(
        .W(5),
        .INITIAL_STATE(WF_RECV)
    ) fsm_u (
        .clk(clk_sys), .rst_n(rst_n),
        .stn(stn), .stc(stc)
    );

    reg signed [23:0] audio_in_r, newer_r, older_r, wet_r, audio_out_r;
    reg [15:0] mix_r, fraction_r;
    reg [7:0] depth_r;
    reg [31:0] phase_r;
    reg [18:0] phase_step_r;
    reg [23:0] offset_r;
    reg [9:0] write_ptr_r, read_new_ptr_r, read_old_ptr_r;
    reg [10:0] valid_count_r;

    wire [34:0] phase_step_product = chorus_rate * PHASE_STEP_K;
    wire [15:0] triangle = phase_r[31] ?
                           ~phase_r[30:15] : phase_r[30:15];
    wire [9:0] delay_samples = 10'd256 + {2'b0, offset_r[23:16]};

    assign ram_read_en = (stc == RAM_READ_NEW || stc == RAM_READ_OLD);
    assign ram_read_addr = RAM_BASE_ADDR +
        {7'd0, (stc == RAM_READ_OLD || stc == RAM_WAIT_OLD_1 ||
                stc == RAM_WAIT_OLD_2 || stc == RAM_WAIT_OLD) ?
                read_old_ptr_r : read_new_ptr_r};
    assign ram_write_en = (stc == RAM_WRITE);
    assign ram_write_addr = RAM_BASE_ADDR + {7'd0, write_ptr_r};
    assign ram_write_data = audio_in_r;

    // 插值和干湿混合分时复用一个同步定点乘法器。
    reg signed [24:0] mult_a_r;
    reg signed [16:0] mult_b_r;
    reg signed [23:0] scaled_base_r;
    wire signed [25:0] mult_scaled;
    signed_fp_mult #(
        .QII_A(10), .QIF_A(15),
        .QII_B(1), .QIF_B(16),
        .QOI(11), .QOF(15)
    ) mult_u (
        .clk(clk_sys), .rst_n(rst_n),
        .in_a(mult_a_r), .in_b(mult_b_r), .out(mult_scaled)
    );

    wire signed [25:0] scaled_sum =
        $signed({{2{scaled_base_r[23]}}, scaled_base_r}) + mult_scaled;
    wire signed [23:0] scaled_sat;
    signed_fp_norm #(
        .QII(11), .QIF(15),
        .QOI(9), .QOF(15)
    ) scaled_sat_u (
        .in(scaled_sum), .out(scaled_sat)
    );

    always @(*)
    begin
        case (stc)
            WF_RECV: stn = in_valid ? LFO_CALC : WF_RECV;
            LFO_CALC: stn = ADDR_CALC;
            ADDR_CALC: stn = RAM_READ_NEW;
            RAM_READ_NEW: stn = RAM_WAIT_NEW_1;
            RAM_WAIT_NEW_1: stn = RAM_WAIT_NEW_2;
            RAM_WAIT_NEW_2: stn = RAM_WAIT_NEW;
            RAM_WAIT_NEW: stn = RAM_READ_OLD;
            RAM_READ_OLD: stn = RAM_WAIT_OLD_1;
            RAM_WAIT_OLD_1: stn = RAM_WAIT_OLD_2;
            RAM_WAIT_OLD_2: stn = RAM_WAIT_OLD;
            RAM_WAIT_OLD: stn = RAM_WRITE;
            RAM_WRITE: stn = INTERP_SETUP;
            INTERP_SETUP: stn = INTERP_MULT;
            INTERP_MULT: stn = INTERP_APPLY;
            INTERP_APPLY: stn = MIX_SETUP;
            MIX_SETUP: stn = MIX_MULT;
            MIX_MULT: stn = MIX_APPLY;
            MIX_APPLY: stn = WF_SEND;
            WF_SEND: stn = out_ready ? WF_RECV : WF_SEND;
            default: stn = WF_RECV;
        endcase
    end

    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            audio_in_r <= '0;
            newer_r <= '0;
            older_r <= '0;
            wet_r <= '0;
            audio_out_r <= '0;
            mix_r <= '0;
            fraction_r <= '0;
            depth_r <= '0;
            phase_r <= '0;
            phase_step_r <= '0;
            offset_r <= '0;
            write_ptr_r <= '0;
            read_new_ptr_r <= '0;
            read_old_ptr_r <= '0;
            valid_count_r <= '0;
            mult_a_r <= '0;
            mult_b_r <= '0;
            scaled_base_r <= '0;
        end
        else
        begin
            case (stc)
                WF_RECV:
                begin
                    if (in_valid)
                    begin
                        audio_in_r <= audio_in;
                        mix_r <= chorus_mix;
                        depth_r <= chorus_depth;
                        phase_step_r <= phase_step_product[34:16];
                    end
                end

                LFO_CALC:
                begin
                    offset_r <= depth_r * triangle;
                    phase_r <= phase_r + {13'd0, phase_step_r};
                end

                ADDR_CALC:
                begin
                    // 10 位减法按 1024 环绕；最小延迟 256，不会同址读写。
                    read_new_ptr_r <= write_ptr_r - delay_samples;
                    read_old_ptr_r <= write_ptr_r - delay_samples - 10'd1;
                    fraction_r <= offset_r[15:0];
                end

                RAM_WAIT_NEW:
                begin
                    newer_r <= valid_count_r >= {1'b0, delay_samples} ?
                               ram_read_data : 24'sd0;
                end

                RAM_WAIT_OLD:
                begin
                    older_r <= valid_count_r >= {1'b0, delay_samples} + 11'd1 ?
                               ram_read_data : 24'sd0;
                end

                RAM_WRITE:
                begin
                    write_ptr_r <= write_ptr_r + 10'd1;
                    if (valid_count_r != 11'd1024)
                        valid_count_r <= valid_count_r + 11'd1;
                end

                INTERP_SETUP:
                begin
                    mult_a_r <= $signed({older_r[23], older_r}) -
                                $signed({newer_r[23], newer_r});
                    mult_b_r <= $signed({1'b0, fraction_r});
                    scaled_base_r <= newer_r;
                end

                INTERP_APPLY: wet_r <= scaled_sat;

                MIX_SETUP:
                begin
                    mult_a_r <= $signed({wet_r[23], wet_r}) -
                                $signed({audio_in_r[23], audio_in_r});
                    mult_b_r <= $signed({1'b0, mix_r});
                    scaled_base_r <= audio_in_r;
                end

                MIX_APPLY: audio_out_r <= scaled_sat;
            endcase
        end
    end

    assign audio_out = audio_out_r;
    assign out_valid = (stc == WF_SEND);
    assign in_ready = (stc == WF_RECV);
endmodule
