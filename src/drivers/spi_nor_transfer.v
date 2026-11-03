/**
 * spi_nor_transfer 模块 v2
 * v2：发送缓存按64位分组暂存，输入长度校验不再驱动672位装载使能。
 * SPI mode 0 单线整包传输；低字节先发，每个字节 MSB 先发。
 * 全部寄存器使用 clk_sys；flash_clk 只是输出引脚，不作为内部时钟。
 * MISO 经两级同步，在低半周期末取样；HALF_PERIOD_CYCLES 必须 >= 4。
 */

/** SPI 包接口
 * in_valid/in_ready：接收 1..84 字节及 in_data，等待期间发送端保持不变。
 * out_valid/out_ready：返回同长度接收数据；背压期间保持数据及 valid。
 * 字节 n 对应 [8*n +: 8]；未传输的接收字节为零。
 * HALF_PERIOD_CYCLES：半个 SCK 的系统周期数，无 Q 格式；默认 50。
 * CS 前置、末沿保持及两次事务间隔各至少一个半周期；复位立即释放 CS。
 */
module spi_nor_transfer
#(
    parameter HALF_PERIOD_CYCLES = 50
)(
    input clk_sys,
    input rst_n,
    input in_valid,
    output in_ready,
    input [6:0] in_length,
    input [671:0] in_data,
    output out_valid,
    input out_ready,
    output [671:0] out_data,
    output flash_cs_n,
    output flash_clk,
    output flash_mosi,
    input flash_miso
);
    localparam COUNT_WIDTH = (HALF_PERIOD_CYCLES > 1) ? $clog2(HALF_PERIOD_CYCLES) : 1;
    localparam STATE_IDLE = 3'd0;
    localparam STATE_LOW = 3'd1;
    localparam STATE_HIGH = 3'd2;
    localparam STATE_TAIL = 3'd3;
    localparam STATE_GAP = 3'd4;
    localparam STATE_RESULT = 3'd5;
    wire [2:0] current_state;
    reg [2:0] next_state;
    reg [COUNT_WIDTH-1:0] counter_r;
    reg [6:0] length_r;
    reg [6:0] byte_index_r;
    reg [2:0] bit_index_r;
    reg [671:0] transmit_r;
    reg [671:0] receive_r;
    reg [7:0] receive_byte_r;
    reg cs_n_r;
    reg clock_r;
    reg mosi_r;
    reg valid_r;
    wire miso_sync;
    wire half_tick;
    wire last_bit;
    wire [671:0] shifted_transmit;
    genvar data_group;
    assign shifted_transmit = {8'd0, transmit_r[671:8]};

    assign half_tick = (counter_r == HALF_PERIOD_CYCLES - 1);
    assign last_bit = (bit_index_r == 3'd7) && (byte_index_r == length_r - 7'd1);
    assign in_ready = rst_n && (current_state == STATE_IDLE) && (HALF_PERIOD_CYCLES >= 4)
        && (in_length >= 7'd1) && (in_length <= 7'd84);
    assign out_valid = valid_r;
    assign out_data = receive_r;
    assign flash_cs_n = cs_n_r;
    assign flash_clk = clock_r;
    assign flash_mosi = mosi_r;

    signal_sync #(.W(1), .INITIAL_VALUE(1'b1)) miso_sync_u (
        .clk(clk_sys), .rst_n(rst_n), .signal_in(flash_miso), .signal_out(miso_sync)
    );
    fsm #(.W(3), .INITIAL_STATE(STATE_IDLE)) fsm_u (
        .clk(clk_sys), .rst_n(rst_n), .stn(next_state), .stc(current_state)
    );

    generate
        for (data_group = 0; data_group < 11; data_group = data_group + 1)
        begin : transmit_groups
            localparam GROUP_WIDTH = (data_group == 10) ? 32 : 64;
            reg capture_r /* synthesis syn_preserve = 1 */;
            always @(posedge clk_sys or negedge rst_n)
            begin
                if (!rst_n) capture_r <= 1'b1;
                else capture_r <= (next_state == STATE_IDLE);
            end
            // 空闲时暂存，真正握手沿后关闭；无需上游额外保持数据。
            // 仅分拆装载使能，SPI位／字节移位时刻与原版本一致。
            always @(posedge clk_sys or negedge rst_n)
            begin
                if (!rst_n)
                    transmit_r[data_group*64 +: GROUP_WIDTH] <= '0;
                else if (capture_r)
                    transmit_r[data_group*64 +: GROUP_WIDTH] <= in_data[data_group*64 +: GROUP_WIDTH];
                else if ((current_state == STATE_HIGH) && half_tick && !last_bit)
                begin
                    if (bit_index_r == 3'd7)
                        transmit_r[data_group*64 +: GROUP_WIDTH] <= shifted_transmit[data_group*64 +: GROUP_WIDTH];
                    else if (data_group == 0)
                        transmit_r[7:0] <= {transmit_r[6:0], 1'b0};
                end
            end
        end
    endgenerate

    always @(*)
    begin
        next_state = current_state;
        case (current_state)
            STATE_IDLE:
                if (in_valid && (HALF_PERIOD_CYCLES >= 4) && (in_length >= 7'd1) && (in_length <= 7'd84))
                    next_state = STATE_LOW;
            STATE_LOW:
                if (half_tick) next_state = STATE_HIGH;
            STATE_HIGH:
                if (half_tick) next_state = last_bit ? STATE_TAIL : STATE_LOW;
            STATE_TAIL:
                if (half_tick) next_state = STATE_GAP;
            STATE_GAP:
                if (half_tick) next_state = STATE_RESULT;
            STATE_RESULT:
                if (out_ready) next_state = STATE_IDLE;
            default: next_state = STATE_IDLE;
        endcase
    end

    // 注册响应有效信号，异步复位仍立即撤销 valid，避免 rst_n 进入下游组合数据路径。
    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n) valid_r <= 1'b0;
        else valid_r <= (next_state == STATE_RESULT);
    end

    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            counter_r <= {COUNT_WIDTH{1'b0}};
            length_r <= 7'd0;
            byte_index_r <= 7'd0;
            bit_index_r <= 3'd0;
            receive_r <= 672'd0;
            receive_byte_r <= 8'd0;
            cs_n_r <= 1'b1;
            clock_r <= 1'b0;
            mosi_r <= 1'b0;
        end
        else
        begin
            // RESULT背压时保持数据；进入空闲后才清空下一笔接收缓存。
            if (current_state == STATE_IDLE) receive_r <= 672'd0;
            if ((current_state == STATE_IDLE) || (current_state == STATE_RESULT) || half_tick)
                counter_r <= {COUNT_WIDTH{1'b0}};
            else
                counter_r <= counter_r + 1'b1;

            if ((current_state == STATE_IDLE) && (next_state == STATE_LOW))
            begin
                length_r <= in_length;
                byte_index_r <= 7'd0;
                bit_index_r <= 3'd0;
                receive_byte_r <= 8'd0;
                cs_n_r <= 1'b0;
                mosi_r <= in_data[7];
            end
            if ((current_state == STATE_LOW) && half_tick)
            begin
                clock_r <= 1'b1;
                receive_byte_r <= {receive_byte_r[6:0], miso_sync};
                if (bit_index_r == 3'd7)
                    receive_r[byte_index_r*8 +: 8] <= {receive_byte_r[6:0], miso_sync};
            end
            if ((current_state == STATE_HIGH) && half_tick)
            begin
                clock_r <= 1'b0;
                if (!last_bit)
                begin
                    bit_index_r <= bit_index_r + 3'd1;
                    if (bit_index_r == 3'd7)
                    begin
                        byte_index_r <= byte_index_r + 7'd1;
                        mosi_r <= transmit_r[15];
                    end
                    else
                    begin
                        mosi_r <= transmit_r[6];
                    end
                end
            end
            if ((current_state == STATE_TAIL) && half_tick)
            begin
                cs_n_r <= 1'b1;
                mosi_r <= 1'b0;
            end
        end
    end
endmodule
