/**
 * ADSR包络子模块
 * 接口定义与组模块类似
 */

module envelope
(
    input clk_sys,
    input rst_n,
    input smp_tick_up,
    input [19:0] attack_ticks,
    input [19:0] decay_ticks,
    input [15:0] sustain_level,
    input [19:0] release_ticks,
    input [31:0] k_a,  // UQ0.32
    input [31:0] k_d,  // UQ0.32
    input [31:0] k_r,  // UQ0.32
    input note_on,
    input note_off,
    
    output [15:0] volume,
    output note_busy,

    input out_ready,
    input in_valid,
    output out_valid,
    output in_ready
);
    // UQ0.32 * UQ20.0 -> UQ0.16
    reg [31:0] mult_k;
    reg [19:0] current_tick;
    wire [15:0] mult_result;
    unsigned_fp_mult #(
        .QII_A(0),
        .QIF_A(32),
        .QII_B(20),
        .QIF_B(0),
        .QOI(0),
        .QOF(16)
    ) ufm_kt_u (
        .clk(clk_sys),
        .rst_n(rst_n),
        .in_a(mult_k),
        .in_b(current_tick),
        .out(mult_result)
    );

    // UQ0.16 - UQ0.16 -> UQ0.16
    reg [15:0] bias;
    wire [15:0] sub_result;
    unsigned_fp_sub #(
        .QII_A(0),
        .QIF_A(16),
        .QII_B(0),
        .QIF_B(16),
        .QOI(0),
        .QOF(16)
    ) ufs_bskt_u (
        .clk(clk_sys),
        .rst_n(rst_n),
        .in_a(bias),
        .in_b(mult_result),
        .out(sub_result)
    );

    localparam WF_TICK = 3'd0, WF_RECV = 3'd1, MULT = 3'd2, SUB = 3'd3, ASSIGN = 3'd4, WF_SEND = 3'd5;

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

    always @(*)
    begin
        case (stc)
            WF_TICK: stn = smp_tick_up ? WF_RECV : WF_TICK;
            WF_RECV: stn = in_valid ? ((note_on | note_off) ? WF_SEND : MULT) : WF_RECV;
            MULT: stn = SUB;  // 乘法占用一个周期
            SUB: stn = ASSIGN;  // 减法占用一个周期
            ASSIGN: stn = WF_SEND;  // 赋值占用一个周期
            WF_SEND: stn = out_ready ? WF_TICK : WF_SEND;
            default: stn = WF_TICK;
        endcase
    end

    localparam ATTACK = 3'd0, DECAY = 3'd1, SUSTAIN = 3'd2, RELEASE = 3'd3, DONE = 3'd4;
    reg [2:0] adsr_state;
    reg [15:0] volume_r;
    reg [15:0] release_start_volume;
    
    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            current_tick <= '0;
            adsr_state <= DONE;
            volume_r <= 16'd0;
            mult_k <= '0;
            bias <= '0;
            release_start_volume <= '0;
        end
        else
        begin
            case (stc)
                WF_RECV:
                begin
                    if (in_valid)
                    begin
                        if (note_on)
                        begin
                            adsr_state <= ATTACK;
                            current_tick <= '0;
                            volume_r <= 16'd0;
                        end
                        else if (note_off)
                        begin
                            adsr_state <= RELEASE;
                            current_tick <= '0;
                            release_start_volume <= volume_r;
                        end
                        else
                        begin
                            current_tick <= (current_tick == '1) ? current_tick : current_tick + 1'b1;  // 默认加1
                            case (adsr_state)
                                ATTACK:
                                    if (current_tick == attack_ticks)
                                    begin
                                        adsr_state <= DECAY;
                                        current_tick <= '0;  // 伪 Attack 阶段，按照 Decay 处理
                                        mult_k <= k_d;
                                        bias <= '1;
                                    end
                                    else
                                    begin
                                        mult_k <= k_a;
                                    end
                                
                                DECAY:
                                    if (current_tick == decay_ticks)
                                    begin
                                        adsr_state <= SUSTAIN;
                                        volume_r <= sustain_level;
                                    end
                                    else
                                    begin
                                        mult_k <= k_d;
                                        bias <= '1;
                                    end

                                SUSTAIN:
                                    volume_r <= sustain_level;

                                RELEASE:
                                    if (current_tick == release_ticks)
                                    begin
                                        adsr_state <= DONE;
                                    end
                                    else
                                    begin
                                        mult_k <= k_r;
                                        bias <= release_start_volume;
                                    end
                            endcase
                        end
                    end
                end

                ASSIGN:
                begin
                    case (adsr_state)
                        ATTACK: volume_r <= mult_result;
                        DECAY: volume_r <= sub_result;
                        SUSTAIN: volume_r <= volume_r;  // 因为之前在valid的时候都锁存了所以不用赋值
                        RELEASE: volume_r <= sub_result;
                        DONE: volume_r <= 16'd0;
                    endcase
                end
            endcase
        end
    end

    assign out_valid = (stc == WF_SEND);
    assign in_ready = (stc == WF_RECV);
    assign volume = volume_r;
    assign note_busy = (adsr_state != DONE);
endmodule
