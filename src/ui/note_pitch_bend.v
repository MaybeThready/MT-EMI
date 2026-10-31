/**
 * 声部弯音模块 v5
 * v5：利用原三拍流水预取下一个声部，索引加一、8选1、组选取分拍处理。
 * v4 版本修改：基频分组暂存，隔开握手判断与装载；恢复四个 16×9 位 LUT 乘法。
 * 计算 note_freq = base_freq * bend_ratio，所有声部分时共用一组乘法流水，不使用 DSP。
 * 32×18 位乘法拆成四个 16×9 位局部乘积，按位权合并为完整 50 位乘积后舍入、饱和。
 * 每声部三拍：局部乘法 → 合并 → 保存；复用 unsigned_fp_mult 和 unsigned_fp_norm。
 */

/**
 * base_freq/note_freq: 32 位 UQ16.16；bend_ratio: 18 位 UQ1.17。
 * 编码换算：note_freq = min(32'hffffffff, (完整乘积 + 2^16) >> 17)。
 * MAX_POLYPHONY >= 1；输入握手后 3*MAX_POLYPHONY 拍结果有效，再下一拍可交付。
 * clk_sys 上升沿 valid && ready 接收或交付；等待接收时保持整组结果与 valid。
 * NOTE: 空闲声部由上游提供零基频；每次从基频计算，不对上次弯音结果重复相乘。
 */
module note_pitch_bend
#(
    parameter MAX_POLYPHONY = 32
)(
    input clk_sys,
    input rst_n,
    input [31:0] base_freq [MAX_POLYPHONY-1:0],
    input [17:0] bend_ratio,
    input in_valid,
    output in_ready,
    output [31:0] note_freq [MAX_POLYPHONY-1:0],
    output out_valid,
    input out_ready
);
    localparam VOICE_INDEX_WIDTH = (MAX_POLYPHONY > 1) ? $clog2(MAX_POLYPHONY) : 1;
    localparam [VOICE_INDEX_WIDTH-1:0] LAST_VOICE = MAX_POLYPHONY - 1;
    localparam STATE_WAIT_FREQUENCIES = 3'd0;
    localparam STATE_CALCULATE_PARTIAL_PRODUCTS = 3'd1;
    localparam STATE_COMBINE_PARTIAL_PRODUCTS = 3'd2;
    localparam STATE_STORE_FREQUENCY = 3'd3;
    localparam STATE_WAIT_AUDIO_ACCEPT = 3'd4;
    localparam LOAD_GROUP_SIZE = 8;
    localparam LOAD_GROUP_COUNT = (MAX_POLYPHONY + LOAD_GROUP_SIZE - 1) / LOAD_GROUP_SIZE;
    wire [2:0] current_state;
    reg [2:0] next_state;
    reg [31:0] base_freq_r [MAX_POLYPHONY-1:0];
    reg [31:0] note_freq_r [MAX_POLYPHONY-1:0];
    reg [17:0] ratio_r;
    reg [31:0] operand_r;
    reg [VOICE_INDEX_WIDTH-1:0] voice_index_r;
    reg [VOICE_INDEX_WIDTH-1:0] next_voice_index_r;
    wire [2:0] next_voice_offset;
    reg [31:0] prefetched_frequency_r [LOAD_GROUP_COUNT-1:0];
    wire [31:0] selected_frequency;
    wire [24:0] partial_product [3:0];
    wire [33:0] low_word_product;
    wire [33:0] high_word_product;
    reg [49:0] product_r;
    wire [31:0] rounded_frequency;
    integer voice;
    genvar output_voice;
    genvar frequency_word;
    genvar ratio_word;
    genvar load_group;

    assign in_ready = rst_n && (current_state == STATE_WAIT_FREQUENCIES);
    assign out_valid = (current_state == STATE_WAIT_AUDIO_ACCEPT);
    generate
        for (output_voice = 0; output_voice < MAX_POLYPHONY; output_voice = output_voice + 1)
        begin : frequency_outputs
            assign note_freq[output_voice] = note_freq_r[output_voice];
        end

        for (load_group = 0; load_group < LOAD_GROUP_COUNT; load_group = load_group + 1)
        begin : frequency_load_groups
            localparam FIRST_VOICE = load_group * LOAD_GROUP_SIZE;
            localparam LAST_VOICE = ((FIRST_VOICE + LOAD_GROUP_SIZE) < MAX_POLYPHONY) ?
                (FIRST_VOICE + LOAD_GROUP_SIZE) : MAX_POLYPHONY;
            // 本地标记与等待输入状态同拍；只驱动本组，保留副本以避免合并。
            reg capture_input_r /* synthesis syn_preserve = 1 */;
            integer group_voice;
            integer prefetch_voice;

            always @(posedge clk_sys or negedge rst_n)
            begin
                if (!rst_n)
                    capture_input_r <= 1'b1;
                else
                    capture_input_r <= (next_state == STATE_WAIT_FREQUENCIES);
            end

            always @(posedge clk_sys or negedge rst_n)
            begin
                if (!rst_n)
                begin
                    for (group_voice = FIRST_VOICE; group_voice < LAST_VOICE; group_voice = group_voice + 1)
                        base_freq_r[group_voice] <= 32'd0;
                end
                else if (capture_input_r)
                begin
                    // 空闲时只暂存；握手沿存入有效帧，之后关闭装载直到本批输出交付。
                    for (group_voice = FIRST_VOICE; group_voice < LAST_VOICE; group_voice = group_voice + 1)
                        base_freq_r[group_voice] <= base_freq[group_voice];
                end
            end
            // CALCULATE 已寄存下一索引，COMBINE 只做本组最多8选1。
            // 固定下标展开，P=1或最后不足8项时也不读取越界数组。
            always @(posedge clk_sys or negedge rst_n)
            begin
                if (!rst_n)
                    prefetched_frequency_r[load_group] <= 32'd0;
                else if (current_state == STATE_COMBINE_PARTIAL_PRODUCTS)
                begin
                    prefetched_frequency_r[load_group] <= 32'd0;
                    for (prefetch_voice = FIRST_VOICE; prefetch_voice < LAST_VOICE; prefetch_voice = prefetch_voice + 1)
                    begin
                        if (next_voice_offset == (prefetch_voice - FIRST_VOICE))
                            prefetched_frequency_r[load_group] <= base_freq_r[prefetch_voice];
                    end
                end
            end
        end
    endgenerate

    // 先按原始无符号位串相乘，拼回 50 位后仍是 UQ17.33，不提前舍入或截断。
    // 首个操作数在输入握手时锁存，后续操作数在保存上一声部时预取，隔开选择与乘法。
    // 每个声部仍三拍：计算局部乘积、合并乘积、舍入保存并预取下一声部。
    generate
        if (VOICE_INDEX_WIDTH >= 3)
        begin : full_voice_offset
            assign next_voice_offset = next_voice_index_r[2:0];
        end
        else
        begin : short_voice_offset
            assign next_voice_offset = {{(3-VOICE_INDEX_WIDTH){1'b0}}, next_voice_index_r};
        end
    endgenerate
    assign selected_frequency = operand_r;
    generate
        for (frequency_word = 0; frequency_word < 2; frequency_word = frequency_word + 1)
        begin : frequency_words
            for (ratio_word = 0; ratio_word < 2; ratio_word = ratio_word + 1)
            begin : ratio_words
                unsigned_fp_mult #(
                    .QII_A(16), .QIF_A(0), .QII_B(9), .QIF_B(0), .QOI(25), .QOF(0)
                ) unsigned_fp_mult_u (
                    .clk(clk_sys), .rst_n(rst_n),
                    .in_a(selected_frequency[16*frequency_word +: 16]),
                    .in_b(ratio_r[9*ratio_word +: 9]),
                    .out(partial_product[2*frequency_word + ratio_word])
                ) /* synthesis syn_dspstyle = "logic" */;
            end
        end
    endgenerate
    assign low_word_product = {9'd0, partial_product[0]} + {partial_product[1], 9'd0};
    assign high_word_product = {9'd0, partial_product[2]} + {partial_product[3], 9'd0};

    unsigned_fp_norm #(.QII(17), .QIF(33), .QOI(16), .QOF(16)) unsigned_fp_norm_u (
        .in(product_r), .out(rounded_frequency)
    );
    fsm #(.W(3), .INITIAL_STATE(STATE_WAIT_FREQUENCIES)) fsm_u (
        .clk(clk_sys), .rst_n(rst_n), .stn(next_state), .stc(current_state)
    );
    always @(*)
    begin
        next_state = current_state;
        case (current_state)
            STATE_WAIT_FREQUENCIES:
                if (in_valid) next_state = STATE_CALCULATE_PARTIAL_PRODUCTS;
            STATE_CALCULATE_PARTIAL_PRODUCTS: next_state = STATE_COMBINE_PARTIAL_PRODUCTS;
            STATE_COMBINE_PARTIAL_PRODUCTS: next_state = STATE_STORE_FREQUENCY;
            STATE_STORE_FREQUENCY:
                next_state = (voice_index_r == LAST_VOICE) ? STATE_WAIT_AUDIO_ACCEPT : STATE_CALCULATE_PARTIAL_PRODUCTS;
            STATE_WAIT_AUDIO_ACCEPT:
                if (out_ready) next_state = STATE_WAIT_FREQUENCIES;
            default: next_state = STATE_WAIT_FREQUENCIES;
        endcase
    end
    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            ratio_r <= 18'd131072;
            operand_r <= 32'd0;
            product_r <= 50'd0;
            voice_index_r <= '0;
            next_voice_index_r <= '0;
            for (voice = 0; voice < MAX_POLYPHONY; voice = voice + 1)
            begin
                note_freq_r[voice] <= 32'd0;
            end
        end
        else
        begin
            case (current_state)
                STATE_WAIT_FREQUENCIES:
                begin
                    // 与各组基频一样在空闲时暂存，只有有效握手才能启动状态机。
                    ratio_r <= bend_ratio;
                    operand_r <= base_freq[0];
                    voice_index_r <= '0;
                end
                // 乘法器每拍寄存输入；本状态仅合并上一拍当前声部的四个局部乘积。
                STATE_CALCULATE_PARTIAL_PRODUCTS:
                    next_voice_index_r <= voice_index_r + {{(VOICE_INDEX_WIDTH-1){1'b0}}, 1'b1};
                STATE_COMBINE_PARTIAL_PRODUCTS:
                    product_r <= {16'd0, low_word_product} + {high_word_product, 16'd0};
                STATE_STORE_FREQUENCY:
                begin
                    note_freq_r[voice_index_r] <= rounded_frequency;
                    if (voice_index_r != LAST_VOICE)
                    begin
                        voice_index_r <= next_voice_index_r;
                        operand_r <= prefetched_frequency_r[next_voice_index_r >> 3];
                    end
                end
                default: ;
            endcase
        end
    end
endmodule
