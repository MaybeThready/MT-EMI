/**
 * 波表端点线性插值模块
 * 分时读取同一相位下的两个波形采样值，复用一个乘法模块完成插值
 */

/**
 * wavetable_0/1: 波形编号 0～3，仅低两位有效
 * wavetable_interp: UQ1.15 插值系数，范围 16'h0000～16'h8000
 * phase: UQ0.12 波表地址
 * sample_point: SQ1.15 插值结果
 * 输入在 in_valid && in_ready 时接收；输出在 out_valid && out_ready 时移交
 */
module wavetable_interpolation
(
    input clk_sys,
    input rst_n,
    input [3:0] wavetable_0,
    input [3:0] wavetable_1,
    input [15:0] wavetable_interp,
    input [11:0] phase,
    output signed [15:0] sample_point,

    input out_ready,
    input in_valid,
    output out_valid,
    output in_ready
);
    reg [1:0] wavetable_0_r, wavetable_1_r;
    reg [15:0] wavetable_interp_r;
    reg [11:0] phase_r;
    reg signed [15:0] sample_0_r, sample_1_r;
    reg signed [16:0] sample_diff_r;  // SQ2.15，可容纳两个端点的完整差值
    reg signed [15:0] sample_point_r;

    localparam WF_RECV = 4'd0, READ_0 = 4'd1, GET_0 = 4'd2,
               READ_1 = 4'd3, GET_1 = 4'd4, SUB = 4'd5,
               MULT = 4'd6, ASSIGN = 4'd7, WF_SEND = 4'd8;

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

    always @(*)
    begin
        case (stc)
            WF_RECV: stn = in_valid ? READ_0 : WF_RECV;
            READ_0: stn = GET_0;
            GET_0: stn = READ_1;
            READ_1: stn = GET_1;
            GET_1: stn = SUB;
            SUB: stn = MULT;
            MULT: stn = ASSIGN;
            ASSIGN: stn = WF_SEND;
            WF_SEND: stn = out_ready ? WF_RECV : WF_SEND;
            default: stn = WF_RECV;
        endcase
    end

    wire [1:0] wavetable_sel = (stc == READ_1 || stc == GET_1) ? wavetable_1_r : wavetable_0_r;
    wire [13:0] rom_addr = {wavetable_sel, phase_r};
    wire [15:0] rom_data;
    rom_wavetables rom_u (
        .dout(rom_data),
        .clk(clk_sys),
        .oce(1'b1),
        .ce(1'b1),
        .reset(1'b0),
        .ad(rom_addr)
    );

    wire signed [16:0] interp_coeff = $signed({1'b0, wavetable_interp_r});  // SQ2.15
    wire signed [16:0] mult_result;
    signed_fp_mult #(
        .QII_A(2),
        .QIF_A(15),
        .QII_B(2),
        .QIF_B(15),
        .QOI(2),
        .QOF(15)
    ) sfm_u (
        .clk(clk_sys),
        .rst_n(rst_n),
        .in_a(sample_diff_r),
        .in_b(interp_coeff),
        .out(mult_result)
    );

    wire signed [16:0] sample_sum = $signed({sample_0_r[15], sample_0_r}) + mult_result;

    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            wavetable_0_r <= '0;
            wavetable_1_r <= '0;
            wavetable_interp_r <= '0;
            phase_r <= '0;
            sample_0_r <= '0;
            sample_1_r <= '0;
            sample_diff_r <= '0;
            sample_point_r <= '0;
        end
        else
        begin
            case (stc)
                WF_RECV:
                begin
                    if (in_valid)
                    begin
                        wavetable_0_r <= wavetable_0[1:0];
                        wavetable_1_r <= wavetable_1[1:0];
                        wavetable_interp_r <= wavetable_interp;
                        phase_r <= phase;
                    end
                end

                GET_0: sample_0_r <= $signed(rom_data);
                GET_1: sample_1_r <= $signed(rom_data);
                SUB: sample_diff_r <= $signed({sample_1_r[15], sample_1_r}) -
                                      $signed({sample_0_r[15], sample_0_r});
                ASSIGN: sample_point_r <= sample_sum[15:0];
            endcase
        end
    end

    assign sample_point = sample_point_r;
    assign out_valid = (stc == WF_SEND);
    assign in_ready = (stc == WF_RECV);
endmodule
