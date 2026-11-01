/**
 * 1024点实数PCM频谱引擎：迭代基2时间抽取FFT，输入使用Hann窗。
 * clk_sys/rst_n连接系统时钟/rst_sys_n；start_valid && start_ready锁定完整PCM窗口。
 * pcm_rd_*为一拍同步读取，输入格式SQ1.15；最后一个采样装载后脉冲window_release。
 * 随后仅使用自身两个1024×16工作存储体，不再占用采集窗口；装载时按位反序，输出自然序正频率谱线。
 * out_valid不依赖out_ready；背压时谱线索引、复数值和幅度保持一致；仅允许一个任务，复位取消当前任务。
 * 实部/虚部为16位有符号SQ1.15，对应FFT(Hann*x)/1024；蝶形就近舍入，中点向正无穷，再饱和到16位。
 * 乘积、旋转与加减保留保护位，最终右移16位，合并Q15旋转系数与每级1/2缩放；fft_overflow报告蝶形截幅。
 * out_magnitude为无符号UQ1.15线性相对幅度，0..0x8000对应0..1FS，不表示功率或dBFS。
 * 整数平方根向下取整；普通正频率谱线乘4，直流/奈奎斯特乘2，补偿单边谱及约1/2的Hann相干增益。
 * amplitude_clipped报告幅度超过1FS，不等同于音频通路错误。
 * Hann、旋转与平方共用一个18×18有符号乘法器；平方根用16次移位减法迭代，无额外乘除法器。
 */
module lcd_fft1024
#(
    parameter MAX_OUTPUT_BIN = 512 // Integer bin0..512; no extra FFT for view crop.
)(
    input clk_sys,
    input rst_n,
    input start_valid,
    output start_ready,
    input [31:0] window_seq,
    output pcm_rd_en,
    output [9:0] pcm_rd_addr,
    input signed [15:0] pcm_rd_data,
    output window_release,
    output busy,
    output done,
    output out_valid,
    input out_ready,
    output [9:0] out_index,
    output signed [15:0] out_real,
    output signed [15:0] out_imag,
    output [15:0] out_magnitude,
    output [31:0] out_seq,
    output [15:0] pcm_peak,
    output fft_overflow,
    output amplitude_clipped,
    output configuration_error
);
    localparam [4:0] IDLE=5'd0, LOAD_READ=5'd1, LOAD_MULT=5'd2, LOAD_WRITE=5'd3,
        READ_A=5'd4, LATCH_A=5'd5, READ_B=5'd6, LATCH_B=5'd7,
        MULT0=5'd8, MULT1=5'd9, MULT2=5'd10, MULT3=5'd11,
        ROTATE=5'd12, WRITE_A=5'd13, WRITE_B=5'd14,
        OUTPUT_READ=5'd15, SQUARE_REAL=5'd16, SQUARE_IMAG=5'd17,
        ROOT_INIT=5'd18, ROOT_STEP=5'd19, OUTPUT_SEND=5'd20, FINISH=5'd21;
    wire [4:0] state;
    reg [4:0] next_state;
    reg [9:0] load_index_r, base_r, j_r, twiddle_phase_r, phase_step_r, output_index_r;
    reg [9:0] half_r;
    reg signed [15:0] ar_r, ai_r, br_r, bi_r;
    reg signed [16:0] cosine_r, sine_r;
    reg signed [17:0] multiply_a, multiply_b;
    reg multiply_enable;
    reg signed [35:0] product_r, product0_r, product1_r, product2_r;
    reg signed [36:0] rotation_real_r, rotation_imag_r;
    reg [31:0] sequence_r, square_real_r, radicand_r;
    reg [15:0] peak_r, root_r, magnitude_r;
    reg [33:0] remainder_r;
    reg [3:0] root_step_r;
    reg release_r, overflow_r, clipped_r;
    wire [15:0] real_data, imag_data;
    reg ram_read, ram_write;
    reg [9:0] ram_rd_addr, ram_wr_addr;
    reg [15:0] ram_wr_real, ram_wr_imag;
    wire coefficient_enable = (state==LOAD_READ) || (state==READ_A) || (state==READ_B);
    wire [9:0] coefficient_phase = (state==LOAD_READ) ? load_index_r :
        ((state==READ_B) ? twiddle_phase_r + 10'd768 : twiddle_phase_r);
    wire signed [16:0] coefficient;
    wire signed [17:0] hann_difference = 18'sd32768 - $signed({coefficient[16],coefficient});
    wire [16:0] hann = (hann_difference + 18'sd1) >>> 1;
    wire signed [35:0] rounded_load = (product_r + 36'sd16384) >>> 15;
    wire signed [36:0] a_real_q30 = $signed({{21{ar_r[15]}},ar_r}) <<< 15;
    wire signed [36:0] a_imag_q30 = $signed({{21{ai_r[15]}},ai_r}) <<< 15;
    wire signed [36:0] add_real = a_real_q30 + rotation_real_r;
    wire signed [36:0] add_imag = a_imag_q30 + rotation_imag_r;
    wire signed [36:0] sub_real = a_real_q30 - rotation_real_r;
    wire signed [36:0] sub_imag = a_imag_q30 - rotation_imag_r;
    wire end_group = (j_r + 10'd1 == half_r);
    wire [10:0] next_group = {1'b0,base_r} + {half_r,1'b0};
    wire end_stage = end_group && (next_group == 11'd1024);
    wire last_butterfly = end_stage && (half_r == 10'd512);
    wire [33:0] shifted_remainder = (remainder_r << 2) | {32'd0,radicand_r[31:30]};
    wire [33:0] root_trial = {16'd0,root_r,2'b01};
    wire subtract_root = (shifted_remainder >= root_trial);
    wire [15:0] next_root = {root_r[14:0],subtract_root};
    wire [17:0] corrected_magnitude = ((output_index_r==10'd0) || (output_index_r==10'd512)) ?
        {1'b0,next_root,1'b0} : {next_root,2'b00};

    assign configuration_error = (MAX_OUTPUT_BIN < 0) || (MAX_OUTPUT_BIN > 512);
    assign start_ready = rst_n && (state==IDLE) && !configuration_error;
    assign busy = (state!=IDLE);
    assign done = (state==FINISH);
    assign pcm_rd_en = (state==LOAD_READ);
    assign pcm_rd_addr = load_index_r;
    assign window_release = release_r;
    assign out_valid = (state==OUTPUT_SEND);
    assign out_index = output_index_r;
    assign out_real = real_data;
    assign out_imag = imag_data;
    assign out_magnitude = magnitude_r;
    assign out_seq = sequence_r;
    assign pcm_peak = peak_r;
    assign fft_overflow = overflow_r;
    assign amplitude_clipped = clipped_r;

    function [9:0] reverse10;
        input [9:0] value;
        integer k;
        begin
            for (k=0; k<10; k=k+1) reverse10[k]=value[9-k];
        end
    endfunction
    function [15:0] quantize;
        input signed [36:0] value;
        reg signed [36:0] scaled;
        begin
            scaled=(value+37'sd32768) >>> 16;
            if (scaled > 37'sd32767) quantize=16'h7fff;
            else if (scaled < -37'sd32768) quantize=16'h8000;
            else quantize=scaled[15:0];
        end
    endfunction
    function overflows;
        input signed [36:0] value;
        reg signed [36:0] scaled;
        begin
            scaled=(value+37'sd32768) >>> 16;
            overflows=(scaled>37'sd32767) || (scaled < -37'sd32768);
        end
    endfunction

    fsm #(.W(5), .INITIAL_STATE(IDLE)) fsm_u (
        .clk(clk_sys), .rst_n(rst_n), .stn(next_state), .stc(state)
    );
    lcd_fft_coeff_rom lcd_fft_coeff_rom_u (
        .clk(clk_sys), .rst_n(rst_n), .en(coefficient_enable),
        .phase(coefficient_phase), .coefficient(coefficient)
    );
    lcd_sdp_ram #(.DATA_WIDTH(16), .DEPTH(1024), .ADDR_WIDTH(10)) real_ram_u (
        .clk(clk_sys), .rst_n(rst_n), .wr_en(ram_write), .wr_addr(ram_wr_addr), .wr_data(ram_wr_real),
        .rd_en(ram_read), .rd_addr(ram_rd_addr), .rd_data(real_data)
    );
    lcd_sdp_ram #(.DATA_WIDTH(16), .DEPTH(1024), .ADDR_WIDTH(10)) imag_ram_u (
        .clk(clk_sys), .rst_n(rst_n), .wr_en(ram_write), .wr_addr(ram_wr_addr), .wr_data(ram_wr_imag),
        .rd_en(ram_read), .rd_addr(ram_rd_addr), .rd_data(imag_data)
    );

    always @(*)
    begin
        next_state=state;
        case (state)
            IDLE: if (start_valid && start_ready) next_state=LOAD_READ;
            LOAD_READ: next_state=LOAD_MULT;
            LOAD_MULT: next_state=LOAD_WRITE;
            LOAD_WRITE: next_state=(load_index_r==10'd1023) ? READ_A : LOAD_READ;
            READ_A: next_state=LATCH_A;
            LATCH_A: next_state=READ_B;
            READ_B: next_state=LATCH_B;
            LATCH_B: next_state=MULT0;
            MULT0: next_state=MULT1;
            MULT1: next_state=MULT2;
            MULT2: next_state=MULT3;
            MULT3: next_state=ROTATE;
            ROTATE: next_state=WRITE_A;
            WRITE_A: next_state=WRITE_B;
            WRITE_B: next_state=last_butterfly ? OUTPUT_READ : READ_A;
            OUTPUT_READ: next_state=SQUARE_REAL;
            SQUARE_REAL: next_state=SQUARE_IMAG;
            SQUARE_IMAG: next_state=ROOT_INIT;
            ROOT_INIT: next_state=ROOT_STEP;
            ROOT_STEP: if (root_step_r==4'd15) next_state=OUTPUT_SEND;
            OUTPUT_SEND: if (out_ready) next_state=(output_index_r==MAX_OUTPUT_BIN) ? FINISH : OUTPUT_READ;
            FINISH: next_state=IDLE;
            default: next_state=IDLE;
        endcase
    end
    always @(*)
    begin
        multiply_enable=1'b1;
        multiply_a=18'sd0;
        multiply_b=18'sd0;
        case (state)
            LOAD_MULT:
            begin
                multiply_a=$signed({{2{pcm_rd_data[15]}},pcm_rd_data});
                multiply_b=$signed({1'b0,hann});
            end
            MULT0, MULT3: multiply_a=$signed({{2{br_r[15]}},br_r});
            MULT1, MULT2: multiply_a=$signed({{2{bi_r[15]}},bi_r});
            SQUARE_REAL:
            begin
                multiply_a=$signed({{2{real_data[15]}},real_data});
                multiply_b=multiply_a;
            end
            SQUARE_IMAG:
            begin
                multiply_a=$signed({{2{imag_data[15]}},imag_data});
                multiply_b=multiply_a;
            end
            default: multiply_enable=1'b0;
        endcase
        if (state==MULT0 || state==MULT2) multiply_b=$signed({cosine_r[16],cosine_r});
        if (state==MULT1 || state==MULT3) multiply_b=$signed({sine_r[16],sine_r});
    end
    always @(*)
    begin
        ram_read=1'b0;
        ram_write=1'b0;
        ram_rd_addr=10'd0;
        ram_wr_addr=10'd0;
        ram_wr_real=16'd0;
        ram_wr_imag=16'd0;
        case (state)
            LOAD_WRITE:
            begin
                ram_write=1'b1;
                ram_wr_addr=reverse10(load_index_r);
                ram_wr_real=rounded_load[15:0];
            end
            READ_A, READ_B:
            begin
                ram_read=1'b1;
                ram_rd_addr=base_r+j_r+((state==READ_B) ? half_r : 10'd0);
            end
            WRITE_A, WRITE_B:
            begin
                ram_write=1'b1;
                ram_wr_addr=base_r+j_r+((state==WRITE_B) ? half_r : 10'd0);
                ram_wr_real=quantize((state==WRITE_A) ? add_real : sub_real);
                ram_wr_imag=quantize((state==WRITE_A) ? add_imag : sub_imag);
            end
            OUTPUT_READ:
            begin
                ram_read=1'b1;
                ram_rd_addr=output_index_r;
            end
            default:
            begin
                // No RAM access while computing or holding a stalled output.
            end
        endcase
    end
    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            load_index_r<=10'd0; base_r<=10'd0; j_r<=10'd0; half_r<=10'd1;
            twiddle_phase_r<=10'd0; phase_step_r<=10'd512; output_index_r<=10'd0;
            ar_r<=16'sd0; ai_r<=16'sd0; br_r<=16'sd0; bi_r<=16'sd0;
            cosine_r<=17'sd0; sine_r<=17'sd0;
            product_r<=36'sd0; product0_r<=36'sd0; product1_r<=36'sd0; product2_r<=36'sd0;
            rotation_real_r<=37'sd0; rotation_imag_r<=37'sd0;
            sequence_r<=32'd0; square_real_r<=32'd0; radicand_r<=32'd0;
            peak_r<=16'd0; root_r<=16'd0; magnitude_r<=16'd0;
            remainder_r<=34'd0; root_step_r<=4'd0;
            release_r<=1'b0; overflow_r<=1'b0; clipped_r<=1'b0;
        end
        else
        begin
            release_r<=1'b0;
            if (multiply_enable) product_r<=multiply_a*multiply_b;
            case (state)
                IDLE:
                    if (start_valid && start_ready)
                    begin
                        sequence_r<=window_seq; load_index_r<=10'd0;
                        base_r<=10'd0; j_r<=10'd0; half_r<=10'd1;
                        twiddle_phase_r<=10'd0; phase_step_r<=10'd512;
                        output_index_r<=10'd0; peak_r<=16'd0;
                        overflow_r<=1'b0; clipped_r<=1'b0;
                    end
                LOAD_MULT:
                    if ((pcm_rd_data[15] ? (~pcm_rd_data+16'd1) : pcm_rd_data) > peak_r)
                        peak_r <= pcm_rd_data[15] ? (~pcm_rd_data+16'd1) : pcm_rd_data;
                LOAD_WRITE:
                begin
                    load_index_r<=load_index_r+10'd1;
                    if (load_index_r==10'd1023) release_r<=1'b1;
                end
                LATCH_A:
                begin
                    ar_r<=$signed(real_data); ai_r<=$signed(imag_data); cosine_r<=coefficient;
                end
                LATCH_B:
                begin
                    br_r<=$signed(real_data); bi_r<=$signed(imag_data); sine_r<=coefficient;
                end
                MULT1: product0_r<=product_r;
                MULT2: product1_r<=product_r;
                MULT3: product2_r<=product_r;
                ROTATE:
                begin
                    rotation_real_r<=$signed({product0_r[35],product0_r})+$signed({product1_r[35],product1_r});
                    rotation_imag_r<=$signed({product2_r[35],product2_r})-$signed({product_r[35],product_r});
                end
                WRITE_A: if (overflows(add_real) || overflows(add_imag)) overflow_r<=1'b1;
                WRITE_B:
                begin
                    if (overflows(sub_real) || overflows(sub_imag)) overflow_r<=1'b1;
                    if (end_group)
                    begin
                        j_r<=10'd0; twiddle_phase_r<=10'd0;
                        if (end_stage)
                        begin
                            base_r<=10'd0;
                            half_r<=half_r<<1;
                            phase_step_r<=phase_step_r>>1;
                        end
                        else base_r<=next_group[9:0];
                    end
                    else
                    begin
                        j_r<=j_r+10'd1;
                        twiddle_phase_r<=twiddle_phase_r+phase_step_r;
                    end
                end
                SQUARE_IMAG: square_real_r<=product_r[31:0];
                ROOT_INIT:
                begin
                    radicand_r<=square_real_r+product_r[31:0];
                    remainder_r<=34'd0; root_r<=16'd0; root_step_r<=4'd0;
                end
                ROOT_STEP:
                begin
                    remainder_r<=subtract_root ? shifted_remainder-root_trial : shifted_remainder;
                    radicand_r<=radicand_r<<2; root_r<=next_root; root_step_r<=root_step_r+4'd1;
                    if (root_step_r==4'd15)
                    begin
                        magnitude_r <= (corrected_magnitude>18'd32768) ? 16'h8000 : corrected_magnitude[15:0];
                        if (corrected_magnitude>18'd32768) clipped_r<=1'b1;
                    end
                end
                OUTPUT_SEND: if (out_ready) output_index_r<=output_index_r+10'd1;
                default:
                begin
                    // States performing reads/writes otherwise retain data.
                end
            endcase
        end
    end
endmodule
