/**
 * 单抽头反馈延迟。每个输入采样从环形 RAM 读取 delay_time 个采样前的值，
 * 将当前输入与反馈后的历史值相加写回 RAM，再按 delay_mix 进行干湿混合。
 * 24 位 SQ9.15 数据贯穿效果器链，写入 RAM 和输出前均饱和，避免回绕。
 * 本模块独占从 RAM_BASE_ADDR 开始的 65536 个 24 位字。
 */

/**
 * clk_sys: 系统时钟；rst_n: 低有效异步复位，只清控制状态，不清外部 RAM
 * audio_in/audio_out: 24 位有符号 SQ9.15 音频采样
 * delay_mix: 干湿比例，UQ0.16；0 为纯干声，16'hffff 近似纯湿声
 * delay_time: 延迟采样数，单位为 smp_tick；0 按 1 处理，最大为 65535
 * delay_feedback: 历史样本反馈系数，UQ0.16，内部限制到 0.9375
 * in_valid/in_ready、out_valid/out_ready: 每个采样各进行一次 valid-ready 握手
 * ram_read_en/ram_read_addr: 发起同步读，数据在下一时钟沿后有效
 * ram_write_en/ram_write_addr/ram_write_data: 在时钟上升沿写入一个采样
 * ram_read_data/ram_write_data: 外部 81920 x 24 SDP RAM 的读写端口；
 *                               两端口均接 clk_sys，输出使能常开
 * RAM_BASE_ADDR: 延迟专用区起始地址，必须满足 RAM_BASE_ADDR + 65536 <= 81920
 * 每次输入握手后，本模块占用 RAM 直到输出握手，不接受下一输入。
 */
module delay
#(
    parameter [16:0] RAM_BASE_ADDR = 17'd8192
)(
    input clk_sys,
    input rst_n,
    input signed [23:0] audio_in,
    input [15:0] delay_mix,
    input [15:0] delay_time,
    input [15:0] delay_feedback,
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
    localparam [15:0] MAX_FEEDBACK = 16'hf000;  // UQ0.16，0.9375
    localparam [16:0] RAM_WORDS = 17'd65536;

    localparam WF_RECV = 4'd0, ADDR_CALC = 4'd1,
               RAM_READ = 4'd2, RAM_WAIT = 4'd3,
               FEEDBACK_SETUP = 4'd4, FEEDBACK_MULT = 4'd5,
               FEEDBACK_APPLY = 4'd6, RAM_WRITE = 4'd7,
               MIX_SETUP = 4'd8, MIX_MULT = 4'd9,
               MIX_APPLY = 4'd10, WF_SEND = 4'd11;

    wire [3:0] stc;
    reg [3:0] stn;
    fsm #(
        .W(4),
        .INITIAL_STATE(WF_RECV)
    ) fsm_u (
        .clk(clk_sys),
        .rst_n(rst_n),
        .stn(stn),
        .stc(stc)
    );

    reg [15:0] write_ptr_r, read_ptr_r, time_r;
    reg [16:0] valid_count_r;
    reg [15:0] mix_r, feedback_r;
    reg signed [23:0] audio_in_r, delayed_r;
    reg signed [23:0] ram_write_data_r, audio_out_r;

    assign ram_read_en = (stc == RAM_READ);
    assign ram_read_addr = RAM_BASE_ADDR + {1'b0, read_ptr_r};
    assign ram_write_en = (stc == RAM_WRITE);
    assign ram_write_addr = RAM_BASE_ADDR + {1'b0, write_ptr_r};
    assign ram_write_data = ram_write_data_r;

    // 反馈和干湿混合分时复用一个同步 signed_fp_mult。
    reg signed [24:0] mult_a_r;
    reg signed [16:0] mult_b_r;
    wire signed [25:0] mult_scaled;
    signed_fp_mult #(
        .QII_A(10), .QIF_A(15),
        .QII_B(1), .QIF_B(16),
        .QOI(11), .QOF(15)
    ) mult_u (
        .clk(clk_sys),
        .rst_n(rst_n),
        .in_a(mult_a_r),
        .in_b(mult_b_r),
        .out(mult_scaled)
    );

    wire signed [25:0] scaled_sum =
        $signed({{2{audio_in_r[23]}}, audio_in_r}) + mult_scaled;
    localparam signed [25:0] AUDIO_MAX = {{3{1'b0}}, {23{1'b1}}};
    localparam signed [25:0] AUDIO_MIN = {{3{1'b1}}, {23{1'b0}}};
    function [23:0] sat_sample;
        input signed [25:0] value;
        begin
            if (value > AUDIO_MAX)
                sat_sample = AUDIO_MAX[23:0];
            else if (value < AUDIO_MIN)
                sat_sample = AUDIO_MIN[23:0];
            else
                sat_sample = value[23:0];
        end
    endfunction

    always @(*)
    begin
        case (stc)
            WF_RECV: stn = in_valid ? ADDR_CALC : WF_RECV;
            ADDR_CALC: stn = RAM_READ;
            RAM_READ: stn = RAM_WAIT;
            RAM_WAIT: stn = FEEDBACK_SETUP;
            FEEDBACK_SETUP: stn = FEEDBACK_MULT;
            FEEDBACK_MULT: stn = FEEDBACK_APPLY;
            FEEDBACK_APPLY: stn = RAM_WRITE;
            RAM_WRITE: stn = MIX_SETUP;
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
            write_ptr_r <= '0;
            read_ptr_r <= '0;
            time_r <= '0;
            valid_count_r <= '0;
            mix_r <= '0;
            feedback_r <= '0;
            audio_in_r <= '0;
            delayed_r <= '0;
            ram_write_data_r <= '0;
            audio_out_r <= '0;
            mult_a_r <= '0;
            mult_b_r <= '0;
        end
        else
        begin
            case (stc)
                WF_RECV:
                begin
                    if (in_valid)
                    begin
                        audio_in_r <= audio_in;
                        mix_r <= delay_mix;
                        time_r <= delay_time == 16'd0 ? 16'd1 : delay_time;
                        feedback_r <= delay_feedback > MAX_FEEDBACK ?
                                      MAX_FEEDBACK : delay_feedback;
                    end
                end

                ADDR_CALC:
                begin
                    // 16 位减法自然按 65536 环绕，读写地址始终不同。
                    read_ptr_r <= write_ptr_r - time_r;
                end

                RAM_WAIT:
                begin
                    // RAM 不清零；历史尚未覆盖该延迟距离时把读数视为零。
                    delayed_r <= valid_count_r >= {1'b0, time_r} ?
                                 ram_read_data : 24'sd0;
                end

                FEEDBACK_SETUP:
                begin
                    mult_a_r <= $signed({delayed_r[23], delayed_r});
                    mult_b_r <= $signed({1'b0, feedback_r});
                end

                FEEDBACK_APPLY:
                begin
                    ram_write_data_r <= sat_sample(scaled_sum);
                end

                RAM_WRITE:
                begin
                    write_ptr_r <= write_ptr_r + 16'd1;
                    if (valid_count_r != RAM_WORDS)
                        valid_count_r <= valid_count_r + 17'd1;
                end

                MIX_SETUP:
                begin
                    mult_a_r <= $signed({delayed_r[23], delayed_r}) -
                                $signed({audio_in_r[23], audio_in_r});
                    mult_b_r <= $signed({1'b0, mix_r});
                end

                MIX_APPLY: audio_out_r <= sat_sample(scaled_sum);
            endcase
        end
    end

    assign audio_out = audio_out_r;
    assign out_valid = (stc == WF_SEND);
    assign in_ready = (stc == WF_RECV);
endmodule
