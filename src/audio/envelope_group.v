/**
 * ADSR包络组模块
 */

`include "../defines.vh"

/**
 * ENVELOPE_NUM: 包络个数
 * attack_ticks: attack 时间
 * decay_ticks: decay 时间
 * sustain_level: sustain 音量，UQ0.16
 * release_ticks: release 时间
 * note_on: 包络触发信号
 * note_off: 包络释放信号
 * volume: 输出音量，UQ0.16
 * note_busy: 复音通道状态
 */
module envelope_group
#(
    parameter ENVELOPE_NUM = 32
)(
    input clk_sys,
    input rst_n,
    input smp_tick_up,
    input [19:0] attack_ticks,
    input [19:0] decay_ticks,
    input [15:0] sustain_level,
    input [19:0] release_ticks,
    input [ENVELOPE_NUM-1:0] note_on,
    input [ENVELOPE_NUM-1:0] note_off,

    output [15:0] volume [ENVELOPE_NUM-1:0],
    output [ENVELOPE_NUM-1:0] note_busy,

    input out_ready,
    input in_valid,
    output out_valid,
    output in_ready
);
    localparam IDX_W = ENVELOPE_NUM > 1 ? $clog2(ENVELOPE_NUM) : 1;
    localparam DIV_CNT_W = $clog2(`ADSR_DIV_LATENCY + 1);

    reg [19:0] attack_ticks_r, decay_ticks_r, release_ticks_r;
    reg [15:0] sustain_level_r;
    reg [ENVELOPE_NUM-1:0] note_on_r, note_off_r;
    reg [19:0] release_ticks_lane [ENVELOPE_NUM-1:0];

    wire [19:0] attack_ticks_w = attack_ticks == 0 ? 20'd1 : attack_ticks;
    wire [19:0] decay_ticks_w = decay_ticks == 0 ? 20'd1 : decay_ticks;
    wire [19:0] release_ticks_w = release_ticks == 0 ? 20'd1 : release_ticks;
    wire [ENVELOPE_NUM-1:0] note_off_w = note_off & ~note_on & note_busy;

    reg [19:0] divisor;
    wire [31:0] div_result;  // 1 / divisor 的 UQ0.32 小数部分
    adsr_division adsr_div_u (
        .clk(clk_sys),
        .rstn(rst_n),
        .dividend(4'd1),
        .divisor(divisor),
        .remainder(div_result),
        .quotient()
    );

    reg [31:0] inv_a, inv_d, inv_r;
    reg [DIV_CNT_W-1:0] div_wait_count;
    reg [IDX_W-1:0] lane_index;

    reg [15:0] mult_a;
    reg [31:0] mult_b;
    wire [31:0] mult_result;
    unsigned_fp_mult #(
        .QII_A(0),
        .QIF_A(16),
        .QII_B(0),
        .QIF_B(32),
        .QOI(0),
        .QOF(32)
    ) ufm_k_u (
        .clk(clk_sys),
        .rst_n(rst_n),
        .in_a(mult_a),
        .in_b(mult_b),
        .out(mult_result)
    );

    reg [31:0] k_a_r, k_d_r;
    reg [31:0] k_r_lane [ENVELOPE_NUM-1:0];

    localparam WF_TICK = 4'd0, WF_RECV = 4'd1,
               DIV_A = 4'd2, DIV_D = 4'd3, DIV_R = 4'd4,
               MULT_A = 4'd5, GET_A = 4'd6,
               MULT_D = 4'd7, GET_D = 4'd8,
               MULT_R = 4'd9, GET_R = 4'd10,
               WF_SUB_RECV = 4'd11, SEND_SUB = 4'd12,
               WF_SUB_SEND = 4'd13, WF_SEND = 4'd14;

    wire [3:0] stc;
    reg [3:0] stn;
    fsm #(
        .W(4),
        .INITIAL_STATE(WF_TICK)
    ) fsm_u (
        .clk(clk_sys),
        .rst_n(rst_n),
        .stn(stn),
        .stc(stc)
    );

    wire div_done = div_wait_count == `ADSR_DIV_LATENCY;
    wire [ENVELOPE_NUM-1:0] out_valids, in_readys;
    wire in_valid_w, out_ready_w;
    localparam VALID_GROUP_NUM = (ENVELOPE_NUM + 7) / 8;
    wire [VALID_GROUP_NUM-1:0] valid_groups_w;
    reg [VALID_GROUP_NUM-1:0] valid_groups_r;

    genvar g;
    generate
        for (g = 0; g < VALID_GROUP_NUM; g = g + 1)
        begin
            localparam GROUP_WIDTH = (g + 1) * 8 > ENVELOPE_NUM ?
                                     ENVELOPE_NUM - g * 8 : 8;
            assign valid_groups_w[g] = &out_valids[g * 8 +: GROUP_WIDTH];
        end
    endgenerate

    always @(*)
    begin
        case (stc)
            WF_TICK: stn = smp_tick_up ? WF_RECV : WF_TICK;
            WF_RECV: stn = in_valid ? DIV_A : WF_RECV;
            DIV_A: stn = div_done ? DIV_D : DIV_A;
            DIV_D: stn = div_done ? DIV_R : DIV_D;
            DIV_R: stn = div_done ? MULT_A : DIV_R;
            MULT_A: stn = GET_A;
            GET_A: stn = MULT_D;
            MULT_D: stn = GET_D;
            GET_D: stn = MULT_R;
            MULT_R: stn = GET_R;
            GET_R: stn = lane_index == ENVELOPE_NUM - 1 ? WF_SUB_RECV : MULT_R;
            WF_SUB_RECV: stn = (&in_readys) ? SEND_SUB : WF_SUB_RECV;
            SEND_SUB: stn = WF_SUB_SEND;
            WF_SUB_SEND: stn = (&valid_groups_r) ? WF_SEND : WF_SUB_SEND;
            WF_SEND: stn = out_ready ? WF_TICK : WF_SEND;
            default: stn = WF_TICK;
        endcase
    end

    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
            valid_groups_r <= '0;
        else if (stc == SEND_SUB)
            valid_groups_r <= '0;
        else
            valid_groups_r <= valid_groups_w;
    end

    always @(*)
    begin
        mult_a = 16'd0;
        mult_b = 32'd0;
        case (stc)
            MULT_A, GET_A:
            begin
                mult_a = 16'hffff;
                mult_b = inv_a;
            end
            MULT_D, GET_D:
            begin
                mult_a = 16'hffff - sustain_level_r;
                mult_b = inv_d;
            end
            MULT_R, GET_R:
            begin
                mult_a = volume[lane_index];
                mult_b = inv_r;
            end
        endcase
    end

    integer j;
    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            attack_ticks_r <= 20'd1;
            decay_ticks_r <= 20'd1;
            release_ticks_r <= 20'd1;
            sustain_level_r <= 16'd0;
            note_on_r <= '0;
            note_off_r <= '0;
            divisor <= 20'd1;
            inv_a <= 32'd0;
            inv_d <= 32'd0;
            inv_r <= 32'd0;
            div_wait_count <= '0;
            lane_index <= '0;
            k_a_r <= 32'd0;
            k_d_r <= 32'd0;
            for (j = 0; j < ENVELOPE_NUM; j = j + 1)
            begin
                release_ticks_lane[j] <= 20'd1;
                k_r_lane[j] <= 32'd0;
            end
        end
        else
        begin
            case (stc)
                WF_RECV:
                begin
                    if (in_valid)
                    begin
                        attack_ticks_r <= attack_ticks_w;
                        decay_ticks_r <= decay_ticks_w;
                        release_ticks_r <= release_ticks_w;
                        sustain_level_r <= sustain_level;
                        note_on_r <= note_on;
                        note_off_r <= note_off_w;
                        divisor <= attack_ticks_w;
                        div_wait_count <= '0;
                        lane_index <= '0;
                        for (j = 0; j < ENVELOPE_NUM; j = j + 1)
                        begin
                            if (note_off_w[j])
                                release_ticks_lane[j] <= release_ticks_w;
                        end
                    end
                end

                DIV_A:
                begin
                    if (div_done)
                    begin
                        inv_a <= divisor == 20'd1 ? 32'hffff_ffff : div_result;
                        divisor <= decay_ticks_r;
                        div_wait_count <= '0;
                    end
                    else
                        div_wait_count <= div_wait_count + 1'b1;
                end

                DIV_D:
                begin
                    if (div_done)
                    begin
                        inv_d <= divisor == 20'd1 ? 32'hffff_ffff : div_result;
                        divisor <= release_ticks_r;
                        div_wait_count <= '0;
                    end
                    else
                        div_wait_count <= div_wait_count + 1'b1;
                end

                DIV_R:
                begin
                    if (div_done)
                    begin
                        inv_r <= divisor == 20'd1 ? 32'hffff_ffff : div_result;
                        div_wait_count <= '0;
                    end
                    else
                        div_wait_count <= div_wait_count + 1'b1;
                end

                GET_A: k_a_r <= mult_result;
                GET_D: k_d_r <= mult_result;
                GET_R:
                begin
                    if (note_off_r[lane_index])
                        k_r_lane[lane_index] <= mult_result;
                    if (lane_index != ENVELOPE_NUM - 1)
                        lane_index <= lane_index + 1'b1;
                end
            endcase
        end
    end

    genvar i;
    generate
        for (i = 0; i < ENVELOPE_NUM; i = i + 1)
        begin
            envelope env_u (
                .clk_sys(clk_sys),
                .rst_n(rst_n),
                .smp_tick_up(smp_tick_up),
                .attack_ticks(attack_ticks_r),
                .decay_ticks(decay_ticks_r),
                .sustain_level(sustain_level_r),
                .release_ticks(release_ticks_lane[i]),
                .k_a(k_a_r),
                .k_d(k_d_r),
                .k_r(k_r_lane[i]),
                .note_on(note_on_r[i]),
                .note_off(note_off_r[i]),
                .volume(volume[i]),
                .note_busy(note_busy[i]),
                .out_ready(out_ready_w),
                .in_valid(in_valid_w),
                .out_valid(out_valids[i]),
                .in_ready(in_readys[i])
            );
        end
    endgenerate

    assign in_valid_w = (stc == SEND_SUB);
    assign out_ready_w = (stc == WF_SEND) & out_ready;
    assign in_ready = (stc == WF_RECV);
    assign out_valid = (stc == WF_SEND);
endmodule
