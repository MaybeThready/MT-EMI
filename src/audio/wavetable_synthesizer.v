/**
 * 波表合成模块
 */

/**
 * OSC_NUM: 振荡器个数
 * phase: UQ0.12 实时相位
 * volume: UQ0.16 音量
 * wavetable0/1: 波形插值端点。0正弦波，1三角波，2锯齿波，3方波
 * wavetable_interp: UQ1.15 [0,1]插值系数
 * audio_out: 单声道音频输出，SQ(1+$clog2(OSC_NUM)).15
 * 输入在 in_valid && in_ready 时接收；输出在 out_valid && out_ready 时移交
 */
module wavetable_synthesizer
#(
    parameter OSC_NUM = 32
)(
    input clk_sys,
    input rst_n,
    input smp_tick_up,
    input [11:0] phase [OSC_NUM-1:0],
    input [15:0] volume [OSC_NUM-1:0],
    input [3:0] wavetable_0,
    input [3:0] wavetable_1,
    input [15:0] wavetable_interp,
    output signed [15+$clog2(OSC_NUM):0] audio_out,
    input out_ready,
    input in_valid,
    output out_valid,
    output in_ready
);
    localparam IDX_W = OSC_NUM > 1 ? $clog2(OSC_NUM) : 1;
    localparam AUDIO_W = 16 + $clog2(OSC_NUM);

    reg [11:0] phase_r [OSC_NUM-1:0];
    reg [15:0] volume_r [OSC_NUM-1:0];
    reg [15:0] volume_lane_r;
    reg [3:0] wavetable_0_r, wavetable_1_r;
    reg [15:0] wavetable_interp_r;
    reg [IDX_W-1:0] lane_index;
    reg signed [AUDIO_W-1:0] audio_sum_r;

    localparam WF_TICK = 3'd0, WF_RECV = 3'd1,
               WF_SUB_RECV = 3'd2, SEND_SUB = 3'd3,
               WF_SUB_SEND = 3'd4, MULT = 3'd5,
               ACCUM = 3'd6, WF_SEND = 3'd7;

    wire [2:0] stc;
    reg [2:0] stn;
    fsm #(
        .W(3),
        .INITIAL_STATE(WF_TICK)
    ) fsm_u (
        .clk(clk_sys),
        .rst_n(rst_n),
        .stn(stn),
        .stc(stc)
    );

    wire signed [15:0] sample_point;
    wire sub_out_valid, sub_in_ready;
    wavetable_interpolation interp_u (
        .clk_sys(clk_sys),
        .rst_n(rst_n),
        .wavetable_0(wavetable_0_r),
        .wavetable_1(wavetable_1_r),
        .wavetable_interp(wavetable_interp_r),
        .phase(phase_r[lane_index]),
        .sample_point(sample_point),
        .out_ready(stc == WF_SUB_SEND),
        .in_valid(stc == SEND_SUB),
        .out_valid(sub_out_valid),
        .in_ready(sub_in_ready)
    );

    wire signed [16:0] volume_coeff = $signed({1'b0, volume_lane_r});
    wire signed [15:0] voice_sample;
    signed_fp_mult #(
        .QII_A(1),
        .QIF_A(15),
        .QII_B(1),
        .QIF_B(16),
        .QOI(1),
        .QOF(15)
    ) mult_u (
        .clk(clk_sys),
        .rst_n(rst_n),
        .in_a(sample_point),
        .in_b(volume_coeff),
        .out(voice_sample)
    );

    always @(*)
    begin
        case (stc)
            WF_TICK: stn = smp_tick_up ? WF_RECV : WF_TICK;
            WF_RECV: stn = in_valid ? WF_SUB_RECV : WF_RECV;
            WF_SUB_RECV: stn = sub_in_ready ? SEND_SUB : WF_SUB_RECV;
            SEND_SUB: stn = WF_SUB_SEND;
            WF_SUB_SEND: stn = sub_out_valid ? MULT : WF_SUB_SEND;
            MULT: stn = ACCUM;
            ACCUM: stn = lane_index == OSC_NUM - 1 ? WF_SEND : WF_SUB_RECV;
            WF_SEND: stn = out_ready ? WF_TICK : WF_SEND;
            default: stn = WF_TICK;
        endcase
    end

    integer i;
    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            wavetable_0_r <= '0;
            wavetable_1_r <= '0;
            wavetable_interp_r <= '0;
            volume_lane_r <= '0;
            lane_index <= '0;
            audio_sum_r <= '0;
            for (i = 0; i < OSC_NUM; i = i + 1)
            begin
                phase_r[i] <= '0;
                volume_r[i] <= '0;
            end
        end
        else
        begin
            case (stc)
                WF_RECV:
                begin
                    if (in_valid)
                    begin
                        wavetable_0_r <= wavetable_0;
                        wavetable_1_r <= wavetable_1;
                        wavetable_interp_r <= wavetable_interp;
                        lane_index <= '0;
                        audio_sum_r <= '0;
                        for (i = 0; i < OSC_NUM; i = i + 1)
                        begin
                            phase_r[i] <= phase[i];
                            volume_r[i] <= volume[i];
                        end
                    end
                end

                SEND_SUB: volume_lane_r <= volume_r[lane_index];
                ACCUM:
                begin
                    audio_sum_r <= audio_sum_r +
                                   {{(AUDIO_W-16){voice_sample[15]}}, voice_sample};
                    if (lane_index != OSC_NUM - 1)
                        lane_index <= lane_index + 1'b1;
                end
            endcase
        end
    end

    assign audio_out = audio_sum_r;
    assign out_valid = (stc == WF_SEND);
    assign in_ready = (stc == WF_RECV);
endmodule

