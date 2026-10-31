/**
 * preset_storage_driver 模块 v2
 * v2：代号差值、选择决定分拍寄存，切断比较到整组记录选择的组合长路径。
 * 时序补充：命令接收后显式选择等待态，避免跨模块 ready 后串联状态加法。
 * 对接既有 UI：16 槽、512 位不透明记录、valid/ready 请求及响应。
 * 核心板 U7 的 0xFE0000..0xFFFFFF 专用于音色；每槽两份独立 4 KiB 扇区。
 * 保存流程：擦除非活动副本、写正文、回读、写提交标记、再次回读。
 * 不擦除活动副本；启动扫描提交标记和 CRC32，按代号选择较新有效副本。
 * NOTE: 驱动不解释 UI 参数/版本，不负责清音；UI 仍执行自己的记录校验。
 */

/** UI 存储接口
 * in_valid/in_ready + in_write/in_slot/in_data：对应 UI storage_out_*。
 * out_valid/out_ready + out_status/out_data：对应 UI storage_in_*。
 * catalog_valid/slot_present：对应 UI storage_catalog_valid/storage_slot_present。
 * out_status：0 成功、1 空槽、2 超时、3 设备不兼容、4 损坏/校验失败、5 WEL、6 配置。
 * 只在 clk_sys 上升沿 valid && ready 时交付；响应背压期间全部字段保持。
 * rst_n 必须接 rst_sys_n。复位会取消逻辑事务；Flash 内部操作可能仍继续。
 * 启动先等待、识别及等待 WIP 清除，再扫描；无启动擦除/写入。
 * 错误后目录失效且锁住硬件访问，后续请求返回同一错误，系统复位后重新识别。
 * POWER_UP_CYCLES 默认 1000000（约 10.18 ms），其余时间参数传至命令层。
 */
module preset_storage_driver
#(
    parameter HALF_PERIOD_CYCLES = 50,
    parameter POWER_UP_CYCLES = 1000000,
    parameter BUSY_TIMEOUT_CYCLES = 100000000,
    parameter RELEASE_WAIT_CYCLES = 4096
)(
    input clk_sys,
    input rst_n,
    input in_valid,
    output in_ready,
    input in_write,
    input [3:0] in_slot,
    input [511:0] in_data,
    output out_valid,
    input out_ready,
    output [2:0] out_status,
    output [511:0] out_data,
    output catalog_valid,
    output [15:0] slot_present,
    output [23:0] jedec_id,
    output flash_cs_n,
    output flash_clk,
    output flash_mosi,
    input flash_miso,
    output flash_wp_n,
    output flash_hold_n
);
    localparam STATE_POWER = 5'd0;
    localparam STATE_PROBE = 5'd1;
    localparam STATE_PROBE_WAIT = 5'd2;
    localparam STATE_READ = 5'd3;
    localparam STATE_READ_WAIT = 5'd4;
    localparam STATE_CRC_INIT = 5'd5;
    localparam STATE_CRC = 5'd6;
    localparam STATE_EVALUATE = 5'd7;
    localparam STATE_SELECT = 5'd8;
    localparam STATE_IDLE = 5'd9;
    localparam STATE_BUILD = 5'd10;
    localparam STATE_ERASE = 5'd11;
    localparam STATE_ERASE_WAIT = 5'd12;
    localparam STATE_PROGRAM = 5'd13;
    localparam STATE_PROGRAM_WAIT = 5'd14;
    localparam STATE_VERIFY_BODY = 5'd15;
    localparam STATE_VERIFY_BODY_WAIT = 5'd16;
    localparam STATE_COMMIT = 5'd17;
    localparam STATE_COMMIT_WAIT = 5'd18;
    localparam STATE_VERIFY = 5'd19;
    localparam STATE_VERIFY_WAIT = 5'd20;
    localparam STATE_RESULT = 5'd21;
    localparam STATE_CHECK_BODY = 5'd22;
    localparam STATE_CHECK_FINAL = 5'd23;
    localparam STATE_COMPARE = 5'd24;
    localparam RECORD_MAGIC = 32'h3150544d;
    localparam COMMIT_MARK = 32'h434f4d54;
    wire [4:0] current_state;
    reg [4:0] next_state;
    reg [31:0] power_counter_r;
    reg boot_r;
    reg fault_r;
    reg [2:0] fault_status_r;
    reg write_r;
    reg [3:0] slot_r;
    reg bank_r;
    reg [511:0] payload_r;
    reg [639:0] buffer_r;
    reg [639:0] copy_a_r;
    reg valid_a_r;
    reg valid_b_r;
    reg blank_a_r;
    reg blank_b_r;
    reg [31:0] generation_r;
    reg crc_for_write_r;
    reg [575:0] crc_input_r;
    reg [31:0] crc_r;
    reg [9:0] crc_count_r;
    reg [2:0] status_r;
    reg [511:0] result_r;
    reg catalog_r;
    reg [15:0] present_r;
    wire record_valid;
    reg choose_b_r;
    reg [31:0] generation_delta_r;
    wire [639:0] selected_copy;
    wire any_valid;
    wire flash_ready;
    wire flash_valid;
    wire [2:0] flash_status;
    wire [639:0] flash_data;
    reg command_valid;
    reg response_ready;
    reg [1:0] command_operation;
    reg [23:0] command_address;
    reg [6:0] command_length;
    reg [639:0] command_data;
    wire transaction_failed;
    wire verify_failed;
    reg [19:0] compare_equal_r;
    reg [19:0] blank_group_r;
    genvar group_index;

    // 每组 32 位比较后寄存，禁止综合成跨越整个 640 位记录的进位链。
    // WAIT 接收读回数据，CHECK 下一拍使用分组结果；期间不发送新命令。
    generate
        for (group_index = 0; group_index < 20; group_index = group_index + 1)
        begin : record_groups
            always @(posedge clk_sys or negedge rst_n)
            begin
                if (!rst_n)
                begin
                    compare_equal_r[group_index] <= 1'b0;
                    blank_group_r[group_index] <= 1'b0;
                end
                else
                begin
                    compare_equal_r[group_index] <=
                        (flash_data[group_index*32 +: 32] == buffer_r[group_index*32 +: 32]);
                    blank_group_r[group_index] <= &buffer_r[group_index*32 +: 32];
                end
            end
        end
    endgenerate

    assign in_ready = rst_n && (current_state == STATE_IDLE);
    // 异步复位到 STATE_POWER 已保证响应无效，避免复位进入下游数据 CE。
    assign out_valid = (current_state == STATE_RESULT);
    assign out_data = result_r;
    assign out_status = status_r;
    assign catalog_valid = rst_n && catalog_r;
    assign slot_present = present_r;
    assign flash_wp_n = 1'b1;
    assign flash_hold_n = 1'b1;
    assign record_valid = (buffer_r[31:0] == RECORD_MAGIC)
        && (buffer_r[639:608] == COMMIT_MARK) && (buffer_r[607:576] == ~crc_r);
    assign selected_copy = choose_b_r ? buffer_r : copy_a_r;
    assign any_valid = valid_a_r || valid_b_r;
    assign transaction_failed = flash_valid && response_ready && (flash_status != 3'd0);
    assign verify_failed = ((current_state == STATE_CHECK_BODY) || (current_state == STATE_CHECK_FINAL))
        && !(&compare_equal_r);

    spi_nor_flash #(
        .HALF_PERIOD_CYCLES(HALF_PERIOD_CYCLES), .BUSY_TIMEOUT_CYCLES(BUSY_TIMEOUT_CYCLES),
        .RELEASE_WAIT_CYCLES(RELEASE_WAIT_CYCLES)
    ) spi_nor_flash_u (
        .clk_sys(clk_sys), .rst_n(rst_n), .in_valid(command_valid), .in_ready(flash_ready),
        .in_operation(command_operation), .in_address(command_address), .in_length(command_length),
        .in_data(command_data), .out_valid(flash_valid), .out_ready(response_ready),
        .out_status(flash_status), .out_data(flash_data), .jedec_id(jedec_id),
        .flash_cs_n(flash_cs_n), .flash_clk(flash_clk), .flash_mosi(flash_mosi), .flash_miso(flash_miso)
    );
    fsm #(.W(5), .INITIAL_STATE(STATE_POWER)) fsm_u (
        .clk(clk_sys), .rst_n(rst_n), .stn(next_state), .stc(current_state)
    );

    always @(*)
    begin
        next_state = current_state;
        command_valid = 1'b0;
        response_ready = 1'b0;
        command_operation = 2'd0;
        command_address = {7'h7f, slot_r, bank_r, 12'd0};
        command_length = 7'd80;
        command_data = buffer_r;
        case (current_state)
            STATE_POWER:
                if (POWER_UP_CYCLES < 1) next_state = STATE_IDLE;
                else if (power_counter_r >= POWER_UP_CYCLES - 1) next_state = STATE_PROBE;
            STATE_PROBE, STATE_READ, STATE_ERASE, STATE_PROGRAM,
            STATE_VERIFY_BODY, STATE_COMMIT, STATE_VERIFY:
            begin
                command_valid = 1'b1;
                case (current_state)
                    STATE_PROBE: command_operation = 2'd3;
                    STATE_ERASE: command_operation = 2'd2;
                    STATE_PROGRAM:
                    begin
                        command_operation = 2'd1;
                        command_length = 7'd76;
                    end
                    STATE_COMMIT:
                    begin
                        command_operation = 2'd1;
                        command_length = 7'd4;
                        command_address[11:0] = 12'd76;
                        command_data = {608'd0, COMMIT_MARK};
                    end
                    default: ;
                endcase
                if (flash_ready)
                begin
                    case (current_state)
                        STATE_PROBE: next_state = STATE_PROBE_WAIT;
                        STATE_READ: next_state = STATE_READ_WAIT;
                        STATE_ERASE: next_state = STATE_ERASE_WAIT;
                        STATE_PROGRAM: next_state = STATE_PROGRAM_WAIT;
                        STATE_VERIFY_BODY: next_state = STATE_VERIFY_BODY_WAIT;
                        STATE_COMMIT: next_state = STATE_COMMIT_WAIT;
                        STATE_VERIFY: next_state = STATE_VERIFY_WAIT;
                        default: next_state = STATE_POWER;
                    endcase
                end
            end
            STATE_PROBE_WAIT, STATE_READ_WAIT, STATE_ERASE_WAIT, STATE_PROGRAM_WAIT,
            STATE_VERIFY_BODY_WAIT, STATE_COMMIT_WAIT, STATE_VERIFY_WAIT:
            begin
                response_ready = 1'b1;
                if (flash_valid)
                begin
                    case (current_state)
                        STATE_PROBE_WAIT: next_state = STATE_READ;
                        STATE_READ_WAIT: next_state = STATE_CRC_INIT;
                        STATE_ERASE_WAIT: next_state = STATE_PROGRAM;
                        STATE_PROGRAM_WAIT: next_state = STATE_VERIFY_BODY;
                        STATE_VERIFY_BODY_WAIT: next_state = STATE_CHECK_BODY;
                        STATE_COMMIT_WAIT: next_state = STATE_VERIFY;
                        STATE_VERIFY_WAIT: next_state = STATE_CHECK_FINAL;
                        default: next_state = STATE_RESULT;
                    endcase
                    if (transaction_failed || verify_failed)
                        next_state = boot_r ? STATE_IDLE : STATE_RESULT;
                end
            end
            STATE_CRC_INIT: next_state = STATE_CRC;
            STATE_CHECK_BODY: next_state = verify_failed ? STATE_RESULT : STATE_COMMIT;
            STATE_CHECK_FINAL: next_state = STATE_RESULT;
            STATE_CRC:
                if (crc_count_r == 10'd575) next_state = STATE_EVALUATE;
            STATE_EVALUATE:
                if (crc_for_write_r) next_state = STATE_ERASE;
                else next_state = bank_r ? STATE_COMPARE : STATE_READ;
            STATE_COMPARE: next_state = STATE_SELECT;
            STATE_SELECT:
                if (boot_r) next_state = (slot_r == 4'd15) ? STATE_IDLE : STATE_READ;
                else next_state = write_r ? STATE_BUILD : STATE_RESULT;
            STATE_IDLE:
                if (in_valid) next_state = fault_r ? STATE_RESULT : STATE_READ;
            STATE_BUILD: next_state = STATE_CRC_INIT;
            STATE_RESULT:
                if (out_ready) next_state = STATE_IDLE;
            default: next_state = STATE_POWER;
        endcase
    end

    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            power_counter_r <= 32'd0;
            boot_r <= 1'b1;
            fault_r <= 1'b0;
            fault_status_r <= 3'd0;
            write_r <= 1'b0;
            slot_r <= 4'd0;
            bank_r <= 1'b0;
            payload_r <= 512'd0;
            buffer_r <= 640'd0;
            copy_a_r <= 640'd0;
            valid_a_r <= 1'b0;
            valid_b_r <= 1'b0;
            blank_a_r <= 1'b0;
            blank_b_r <= 1'b0;
            generation_r <= 32'd0;
            generation_delta_r <= 32'd0;
            choose_b_r <= 1'b0;
            crc_for_write_r <= 1'b0;
            crc_input_r <= 576'd0;
            crc_r <= 32'hffffffff;
            crc_count_r <= 10'd0;
            status_r <= 3'd0;
            result_r <= 512'd0;
            catalog_r <= 1'b0;
            present_r <= 16'd0;
        end
        else
        begin
            if (current_state == STATE_POWER) power_counter_r <= power_counter_r + 32'd1;
            if ((current_state == STATE_POWER) && (POWER_UP_CYCLES < 1))
            begin
                fault_r <= 1'b1;
                fault_status_r <= 3'd6;
            end
            if (in_valid && (current_state == STATE_IDLE))
            begin
                boot_r <= 1'b0;
                write_r <= in_write;
                slot_r <= in_slot;
                payload_r <= in_data;
                bank_r <= 1'b0;
                result_r <= 512'd0;
                status_r <= fault_r ? fault_status_r : 3'd0;
            end
            if ((current_state == STATE_READ_WAIT) && flash_valid)
            begin
                buffer_r <= flash_data;
                crc_for_write_r <= 1'b0;
            end
            if (current_state == STATE_CRC_INIT)
            begin
                crc_input_r <= buffer_r[575:0];
                crc_r <= 32'hffffffff;
                crc_count_r <= 10'd0;
            end
            if (current_state == STATE_CRC)
            begin
                crc_r <= (crc_r >> 1) ^ ((crc_r[0] ^ crc_input_r[0]) ? 32'hedb88320 : 32'd0);
                crc_input_r <= {1'b0, crc_input_r[575:1]};
                crc_count_r <= crc_count_r + 10'd1;
            end
            if (current_state == STATE_EVALUATE)
            begin
                if (crc_for_write_r) buffer_r[607:576] <= ~crc_r;
                else if (!bank_r)
                begin
                    copy_a_r <= buffer_r;
                    valid_a_r <= record_valid;
                    blank_a_r <= (&blank_group_r);
                    bank_r <= 1'b1;
                end
                else
                begin
                    valid_b_r <= record_valid;
                    blank_b_r <= (&blank_group_r);
                    generation_delta_r <= buffer_r[63:32] - copy_a_r[63:32];
                end
            end
            // EVALUATE 保存差值及 B 有效性，COMPARE 保存选择，SELECT 才使用。
            // 保留模 2^32 的代号顺序；代号相同时仍优先 B。
            if (current_state == STATE_COMPARE)
                choose_b_r <= valid_b_r && (!valid_a_r || !generation_delta_r[31]);
            if (current_state == STATE_SELECT)
            begin
                present_r[slot_r] <= any_valid;
                if (boot_r)
                begin
                    bank_r <= 1'b0;
                    slot_r <= slot_r + 4'd1;
                    if (slot_r == 4'd15)
                    begin
                        catalog_r <= 1'b1;
                        boot_r <= 1'b0;
                    end
                end
                else if (write_r)
                begin
                    bank_r <= any_valid ? !choose_b_r : 1'b0;
                    generation_r <= any_valid ? selected_copy[63:32] + 32'd1 : 32'd0;
                end
                else if (any_valid) result_r <= selected_copy[575:64];
                else status_r <= (blank_a_r && blank_b_r) ? 3'd1 : 3'd4;
            end
            if (current_state == STATE_BUILD)
            begin
                buffer_r <= {64'hffffffffffffffff, payload_r, generation_r, RECORD_MAGIC};
                crc_for_write_r <= 1'b1;
            end
            if ((current_state == STATE_CHECK_BODY) && !verify_failed)
                buffer_r[639:608] <= COMMIT_MARK;
            if ((current_state == STATE_CHECK_FINAL) && !verify_failed)
                present_r[slot_r] <= 1'b1;
            if (transaction_failed || verify_failed)
            begin
                status_r <= transaction_failed ? flash_status : 3'd4;
                fault_status_r <= transaction_failed ? flash_status : 3'd4;
                fault_r <= 1'b1;
                catalog_r <= 1'b0;
            end
        end
    end
endmodule
