/**
 * Schroeder 混响：四路并联反馈梳状滤波器，后接两级串联全通滤波器。
 * 延迟样本保存在 mixer 持有的音频 SDP 块 RAM 中。本模块独占从
 * RAM_BASE_ADDR 开始的 7494 个 24 位字；mixer 不得将这段地址分配给其他效果器。
 * 32 路复音输入为 21 位 SQ6.15，本级计算和向下一级传输使用 24 位 SQ9.15；
 * 延迟历史与效果器链保持相同的 15 位小数精度，不再逐级压缩。
 * 最终输出 16 位 PCM 的增益和限幅由 mixer 在效果器链末端完成。
 */

/**
 * clk_sys: 系统时钟；rst_n: 低有效异步复位，仅清控制状态，不清外部 RAM
 * audio_in: 复音求和，SQ(1+$clog2(MAX_POLYPHONY)).15
 * audio_out: 发往下一效果器的高位宽采样，SQ(4+$clog2(MAX_POLYPHONY)).15
 * reverb_mix: 干湿比例，UQ0.16；0 为原音，16'hFFFF 近似全湿
 * reverb_feedback: 四路梳状滤波器的反馈/衰减系数，UQ0.16，内部限至 0.9375
 * reverb_damping: 反馈路径的一阶低通系数，UQ0.16；越大高频衰减越强，
 *                 内部限至 0.9375，避免滤波状态接近冻结
 * in_valid/in_ready、out_valid/out_ready: 每个采样点各进行一次 valid-ready 握手
 * ram_read_en/ram_read_addr: 发起一次同步读；读数据在下一个时钟沿后有效
 * ram_write_en/ram_write_addr/ram_write_data: 在时钟上升沿写入一个字
 * ram_read_data/ram_write_data: 24 位有符号历史值，SQ9.15；外部 SDP RAM
 *                               为 81920 x 24，读写时钟都接 clk_sys，输出使能常开
 * RAM_BASE_ADDR: 混响专用区起始地址，必须满足 RAM_BASE_ADDR + 7494 <= 81920
 * 每次输入握手后，本模块占用 RAM 直到输出握手，不接受下一个输入。
 */
module reverb
#(
    parameter MAX_POLYPHONY = 32,
    parameter [16:0] RAM_BASE_ADDR = 17'd0
)(
    input clk_sys,
    input rst_n,
    input signed [15+$clog2(MAX_POLYPHONY):0] audio_in,
    input [15:0] reverb_mix,
    input [15:0] reverb_feedback,
    input [15:0] reverb_damping,
    output signed [18+$clog2(MAX_POLYPHONY):0] audio_out,
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
    localparam INPUT_W = 16 + $clog2(MAX_POLYPHONY);
    localparam PROCESS_W = INPUT_W + 3;

    // 48 kHz 下梳状延迟约为 31、33、36、39 ms，全通延迟约为 5、12 ms。
    localparam [11:0] COMB_0_LEN = 12'd1499;
    localparam [11:0] COMB_1_LEN = 12'd1601;
    localparam [11:0] COMB_2_LEN = 12'd1747;
    localparam [11:0] COMB_3_LEN = 12'd1867;
    localparam [11:0] ALLPASS_0_LEN = 12'd223;
    localparam [11:0] ALLPASS_1_LEN = 12'd557;
    localparam [15:0] MAX_COEFF = 16'hf000;  // UQ0.16，0.9375
    localparam [16:0] COMB_0_BASE = RAM_BASE_ADDR;
    localparam [16:0] COMB_1_BASE = COMB_0_BASE + COMB_0_LEN;
    localparam [16:0] COMB_2_BASE = COMB_1_BASE + COMB_1_LEN;
    localparam [16:0] COMB_3_BASE = COMB_2_BASE + COMB_2_LEN;
    localparam [16:0] ALLPASS_0_BASE = COMB_3_BASE + COMB_3_LEN;
    localparam [16:0] ALLPASS_1_BASE = ALLPASS_0_BASE + ALLPASS_0_LEN;

    localparam WF_RECV = 4'd0, RAM_READ = 4'd1, RAM_WAIT = 4'd2,
               DAMP_SETUP = 4'd3, DAMP_MULT = 4'd4, DAMP_APPLY = 4'd5,
               FEEDBACK_SETUP = 4'd6, FEEDBACK_MULT = 4'd7,
               FEEDBACK_APPLY = 4'd8, ALLPASS_CALC = 4'd9,
               RAM_WRITE = 4'd10, MIX_SETUP = 4'd11,
               MIX_MULT = 4'd12, MIX_APPLY = 4'd13, WF_SEND = 4'd14;

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

    reg [2:0] stage_index;
    reg [11:0] delay_ptr [0:5];
    reg [11:0] valid_count [0:5];
    reg signed [PROCESS_W-1:0] filter_state [0:3];
    reg signed [PROCESS_W-1:0] audio_in_r, delayed_r, damped_r;
    reg signed [PROCESS_W-1:0] stage_input_r, wet_r, audio_out_r;
    reg signed [PROCESS_W-1:0] ram_write_data_r;
    reg signed [PROCESS_W+1:0] comb_sum_r;
    reg [15:0] mix_r, feedback_r, damping_r;

    reg [16:0] stage_base;
    reg [11:0] stage_len;
    always @(*)
    begin
        case (stage_index)
            3'd0:
            begin
                stage_base = COMB_0_BASE;
                stage_len = COMB_0_LEN;
            end
            3'd1:
            begin
                stage_base = COMB_1_BASE;
                stage_len = COMB_1_LEN;
            end
            3'd2:
            begin
                stage_base = COMB_2_BASE;
                stage_len = COMB_2_LEN;
            end
            3'd3:
            begin
                stage_base = COMB_3_BASE;
                stage_len = COMB_3_LEN;
            end
            3'd4:
            begin
                stage_base = ALLPASS_0_BASE;
                stage_len = ALLPASS_0_LEN;
            end
            default:
            begin
                stage_base = ALLPASS_1_BASE;
                stage_len = ALLPASS_1_LEN;
            end
        endcase
    end

    wire [16:0] stage_addr = stage_base + delay_ptr[stage_index];
    assign ram_read_addr = stage_addr;
    assign ram_write_addr = stage_addr;
    assign ram_read_en = (stc == RAM_READ);
    assign ram_write_en = (stc == RAM_WRITE);

    // RAM 固定为 SQ9.15；MAX_POLYPHONY 改变时，只调整整数位并在必要时饱和。
    wire signed [PROCESS_W-1:0] delayed_data;
    signed_fp_norm #(
        .QII(9), .QIF(15),
        .QOI(PROCESS_W - 15), .QOF(15)
    ) ram_read_norm_u (
        .in(ram_read_data), .out(delayed_data)
    );
    signed_fp_norm #(
        .QII(PROCESS_W - 15), .QIF(15),
        .QOI(9), .QOF(15)
    ) ram_write_norm_u (
        .in(ram_write_data_r), .out(ram_write_data)
    );

    // 共享一个 signed_fp_mult，其一拍结果在相应 APPLY 状态读取。
    reg signed [PROCESS_W:0] mult_a_r;
    reg signed [16:0] mult_b_r;
    wire signed [PROCESS_W+1:0] mult_scaled;
    signed_fp_mult #(
        .QII_A(PROCESS_W - 14), .QIF_A(15),
        .QII_B(1), .QIF_B(16),
        .QOI(PROCESS_W - 13), .QOF(15)
    ) mult_u (
        .clk(clk_sys), .rst_n(rst_n),
        .in_a(mult_a_r), .in_b(mult_b_r), .out(mult_scaled)
    );

    wire signed [PROCESS_W-1:0] comb_input = audio_in_r >>> 2;
    wire signed [PROCESS_W+1:0] damp_sum =
        $signed({{2{delayed_r[PROCESS_W-1]}}, delayed_r}) + mult_scaled;
    wire signed [PROCESS_W+1:0] feedback_sum =
        $signed({{2{comb_input[PROCESS_W-1]}}, comb_input}) + mult_scaled;
    wire signed [PROCESS_W+1:0] allpass_output =
        $signed({{2{delayed_r[PROCESS_W-1]}}, delayed_r}) -
        ($signed({{2{stage_input_r[PROCESS_W-1]}}, stage_input_r}) >>> 1);
    wire signed [PROCESS_W+1:0] allpass_write =
        $signed({{2{stage_input_r[PROCESS_W-1]}}, stage_input_r}) +
        (allpass_output >>> 1);
    wire signed [PROCESS_W+1:0] mix_sum =
        $signed({{2{audio_in_r[PROCESS_W-1]}}, audio_in_r}) + mult_scaled;

    wire signed [PROCESS_W-1:0] damped_sat, feedback_sat;
    wire signed [PROCESS_W-1:0] allpass_output_sat, allpass_write_sat;
    wire signed [PROCESS_W-1:0] comb_sum_sat, mix_sat;
    signed_fp_norm #(
        .QII(PROCESS_W - 13), .QIF(15),
        .QOI(PROCESS_W - 15), .QOF(15)
    ) damped_sat_u (
        .in(damp_sum), .out(damped_sat)
    );
    signed_fp_norm #(
        .QII(PROCESS_W - 13), .QIF(15),
        .QOI(PROCESS_W - 15), .QOF(15)
    ) feedback_sat_u (
        .in(feedback_sum), .out(feedback_sat)
    );
    signed_fp_norm #(
        .QII(PROCESS_W - 13), .QIF(15),
        .QOI(PROCESS_W - 15), .QOF(15)
    ) allpass_output_sat_u (
        .in(allpass_output), .out(allpass_output_sat)
    );
    signed_fp_norm #(
        .QII(PROCESS_W - 13), .QIF(15),
        .QOI(PROCESS_W - 15), .QOF(15)
    ) allpass_write_sat_u (
        .in(allpass_write), .out(allpass_write_sat)
    );
    signed_fp_norm #(
        .QII(PROCESS_W - 13), .QIF(15),
        .QOI(PROCESS_W - 15), .QOF(15)
    ) comb_sum_sat_u (
        .in(comb_sum_r), .out(comb_sum_sat)
    );
    signed_fp_norm #(
        .QII(PROCESS_W - 13), .QIF(15),
        .QOI(PROCESS_W - 15), .QOF(15)
    ) mix_sat_u (
        .in(mix_sum), .out(mix_sat)
    );

    always @(*)
    begin
        case (stc)
            WF_RECV: stn = in_valid ? RAM_READ : WF_RECV;
            RAM_READ: stn = RAM_WAIT;
            RAM_WAIT: stn = stage_index < 3'd4 ? DAMP_SETUP : ALLPASS_CALC;
            DAMP_SETUP: stn = DAMP_MULT;
            DAMP_MULT: stn = DAMP_APPLY;
            DAMP_APPLY: stn = FEEDBACK_SETUP;
            FEEDBACK_SETUP: stn = FEEDBACK_MULT;
            FEEDBACK_MULT: stn = FEEDBACK_APPLY;
            FEEDBACK_APPLY: stn = RAM_WRITE;
            ALLPASS_CALC: stn = RAM_WRITE;
            RAM_WRITE: stn = stage_index == 3'd5 ? MIX_SETUP : RAM_READ;
            MIX_SETUP: stn = MIX_MULT;
            MIX_MULT: stn = MIX_APPLY;
            MIX_APPLY: stn = WF_SEND;
            WF_SEND: stn = out_ready ? WF_RECV : WF_SEND;
            default: stn = WF_RECV;
        endcase
    end

    integer i;
    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            stage_index <= '0;
            audio_in_r <= '0;
            delayed_r <= '0;
            damped_r <= '0;
            stage_input_r <= '0;
            wet_r <= '0;
            audio_out_r <= '0;
            ram_write_data_r <= '0;
            comb_sum_r <= '0;
            mix_r <= '0;
            feedback_r <= '0;
            damping_r <= '0;
            mult_a_r <= '0;
            mult_b_r <= '0;
            for (i = 0; i < 6; i = i + 1)
            begin
                delay_ptr[i] <= '0;
                valid_count[i] <= '0;
            end
            for (i = 0; i < 4; i = i + 1)
                filter_state[i] <= '0;
        end
        else
        begin
            case (stc)
                WF_RECV:
                begin
                    if (in_valid)
                    begin
                        audio_in_r <= audio_in;
                        mix_r <= reverb_mix;
                        feedback_r <= reverb_feedback > MAX_COEFF ?
                                      MAX_COEFF : reverb_feedback;
                        damping_r <= reverb_damping > MAX_COEFF ?
                                     MAX_COEFF : reverb_damping;
                        stage_index <= 3'd0;
                        comb_sum_r <= '0;
                    end
                end

                RAM_WAIT:
                begin
                    // 复位后 RAM 内容未知；每段写满之前，未写过的位置视为零。
                    delayed_r <= valid_count[stage_index] == stage_len ?
                                 delayed_data : '0;
                end

                DAMP_SETUP:
                begin
                    mult_a_r <= $signed({filter_state[stage_index][PROCESS_W-1],
                                         filter_state[stage_index]}) -
                                $signed({delayed_r[PROCESS_W-1], delayed_r});
                    mult_b_r <= $signed({1'b0, damping_r});
                end

                DAMP_APPLY:
                begin
                    damped_r <= damped_sat;
                    filter_state[stage_index] <= damped_sat;
                end

                FEEDBACK_SETUP:
                begin
                    mult_a_r <= $signed({damped_r[PROCESS_W-1], damped_r}) -
                                $signed({comb_input[PROCESS_W-1], comb_input});
                    mult_b_r <= $signed({1'b0, feedback_r});
                end

                FEEDBACK_APPLY:
                begin
                    // 输入除以四，再作凸组合，避免反馈级增益随系数增大而失控。
                    ram_write_data_r <= feedback_sat;
                    comb_sum_r <= comb_sum_r +
                                  {{2{delayed_r[PROCESS_W-1]}}, delayed_r};
                end

                ALLPASS_CALC:
                begin
                    // 全通系数固定为 0.5；写入和输出都饱和，决不回绕。
                    ram_write_data_r <= allpass_write_sat;
                    if (stage_index == 3'd4)
                        stage_input_r <= allpass_output_sat;
                    else
                        wet_r <= allpass_output_sat;
                end

                RAM_WRITE:
                begin
                    if (delay_ptr[stage_index] == stage_len - 12'd1)
                        delay_ptr[stage_index] <= 12'd0;
                    else
                        delay_ptr[stage_index] <= delay_ptr[stage_index] + 12'd1;

                    if (valid_count[stage_index] != stage_len)
                        valid_count[stage_index] <= valid_count[stage_index] + 12'd1;

                    if (stage_index == 3'd3)
                        stage_input_r <= comb_sum_sat;

                    if (stage_index != 3'd5)
                        stage_index <= stage_index + 3'd1;
                end

                MIX_SETUP:
                begin
                    mult_a_r <= $signed({wet_r[PROCESS_W-1], wet_r}) -
                                $signed({audio_in_r[PROCESS_W-1], audio_in_r});
                    mult_b_r <= $signed({1'b0, mix_r});
                end

                MIX_APPLY: audio_out_r <= mix_sat;
            endcase
        end
    end

    assign audio_out = audio_out_r;
    assign out_valid = (stc == WF_SEND);
    assign in_ready = (stc == WF_RECV);
endmodule
