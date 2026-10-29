/**
 * ui_preset_controller 模块 v2
 * v2 版本修改：装载 valid 由复位后无效的状态产生，去掉重复复位门控。
 * 执行一次音色保存或读取，复用记录校验模块；最多有一笔未完成事务。
 * command_write=1 保存当前参数，=0 读取；命令握手时锁存槽号及参数。
 * storage_in_status: 0 成功、1 空槽、其余为失败。
 * 保存成功响应必须表示已可靠写入；复位时驱动须同时取消旧事务。
 * apply_* 仅在读取且格式、CRC、参数范围全部正确后有效，整组原子装载。
 * result_status: 0 成功、1 空槽、2 驱动错误、3 CRC、4 格式、5 范围、6 扩展。
 * 所有接口以 clk_sys 上升沿 valid && ready 交付，等待时保持内容不变。
 * TODO: 本轮已通过系统顶层接入实际存储驱动，清音仍待后续；无超时猜测，驱动必须返回明确结果。
 */
module ui_preset_controller
(
    input clk_sys,
    input rst_n,
    input command_valid,
    output command_ready,
    input command_write,
    input [3:0] command_slot,
    input [191:0] current_parameters,
    input [6:0] current_balance_percent,  // 音色增益，随命令与参数同时锁存；不是 master_volume
    output storage_out_valid,
    input storage_out_ready,
    output storage_out_write,
    output [3:0] storage_out_slot,
    output [511:0] storage_out_data,
    input storage_in_valid,
    output storage_in_ready,
    input [2:0] storage_in_status,
    input [511:0] storage_in_data,
    output apply_valid,
    input apply_ready,
    output [191:0] apply_parameters,
    output [6:0] apply_balance_percent,  // 与 apply_valid/ready 同拍装载
    output result_valid,
    input result_ready,
    output [3:0] result_status
);
    localparam STATE_WAIT_COMMAND = 4'd0;
    localparam STATE_START_RECORD_CODEC = 4'd1;
    localparam STATE_WAIT_RECORD_CODEC = 4'd2;
    localparam STATE_SEND_STORAGE_REQUEST = 4'd3;
    localparam STATE_WAIT_STORAGE_RESPONSE = 4'd4;
    localparam STATE_APPLY_LOADED_PARAMETERS = 4'd5;
    localparam STATE_REPORT_RESULT = 4'd6;
    wire [3:0] current_state;
    reg [3:0] next_state;
    reg write_r;
    reg [3:0] slot_r;
    reg [191:0] parameters_r;
    reg [6:0] balance_percent_r;
    wire [6:0] codec_balance_percent;
    reg [511:0] record_r;
    reg [3:0] status_r;
    wire codec_ready;
    wire codec_valid;
    wire [2:0] codec_status;
    wire [511:0] codec_record;
    wire [191:0] codec_parameters;

    assign command_ready = rst_n && (current_state == STATE_WAIT_COMMAND);
    assign storage_out_valid = rst_n && (current_state == STATE_SEND_STORAGE_REQUEST);
    assign storage_out_write = write_r;
    assign storage_out_slot = slot_r;
    assign storage_out_data = record_r;
    assign storage_in_ready = rst_n && (current_state == STATE_WAIT_STORAGE_RESPONSE);
    // 状态机异步复位到等待命令，装载状态本身已排除复位。
    assign apply_valid = (current_state == STATE_APPLY_LOADED_PARAMETERS);
    assign apply_parameters = parameters_r;
    assign apply_balance_percent = balance_percent_r;
    assign result_valid = rst_n && (current_state == STATE_REPORT_RESULT);
    assign result_status = status_r;

    fsm #(.W(4), .INITIAL_STATE(STATE_WAIT_COMMAND)) fsm_u (
        .clk(clk_sys), .rst_n(rst_n), .stn(next_state), .stc(current_state)
    );
    preset_record_codec preset_record_codec_u (
        .clk_sys(clk_sys), .rst_n(rst_n), .decode(!write_r), .slot(slot_r),
        .parameters(parameters_r), .balance_percent(balance_percent_r),
        .balance_percent_out(codec_balance_percent), .record_in(record_r),
        .in_valid(current_state == STATE_START_RECORD_CODEC), .in_ready(codec_ready),
        .record_out(codec_record), .parameters_out(codec_parameters), .status(codec_status),
        .out_valid(codec_valid), .out_ready(current_state == STATE_WAIT_RECORD_CODEC)
    );

    always @(*)
    begin
        next_state = current_state;
        case (current_state)
            STATE_WAIT_COMMAND:
                if (command_valid)
                    next_state = command_write ? STATE_START_RECORD_CODEC : STATE_SEND_STORAGE_REQUEST;
            STATE_START_RECORD_CODEC:
                if (codec_ready) next_state = STATE_WAIT_RECORD_CODEC;
            STATE_WAIT_RECORD_CODEC:
                if (codec_valid)
                begin
                    if (codec_status != 3'd0) next_state = STATE_REPORT_RESULT;
                    else next_state = write_r ? STATE_SEND_STORAGE_REQUEST : STATE_APPLY_LOADED_PARAMETERS;
                end
            STATE_SEND_STORAGE_REQUEST:
                if (storage_out_ready) next_state = STATE_WAIT_STORAGE_RESPONSE;
            STATE_WAIT_STORAGE_RESPONSE:
                if (storage_in_valid)
                begin
                    if ((storage_in_status != 3'd0) || write_r) next_state = STATE_REPORT_RESULT;
                    else next_state = STATE_START_RECORD_CODEC;
                end
            STATE_APPLY_LOADED_PARAMETERS:
                if (apply_ready) next_state = STATE_REPORT_RESULT;
            STATE_REPORT_RESULT:
                if (result_ready) next_state = STATE_WAIT_COMMAND;
            default: next_state = STATE_WAIT_COMMAND;
        endcase
    end

    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            write_r <= 1'b0;
            slot_r <= 4'd0;
            parameters_r <= 192'd0;
            balance_percent_r <= 7'd100;
            record_r <= 512'd0;
            status_r <= 4'd0;
        end
        else
        begin
            // 外层已处理复位；内部直接判断状态，公共 ready 仍保留复位门控。
            if (command_valid && (current_state == STATE_WAIT_COMMAND))
            begin
                write_r <= command_write;
                slot_r <= command_slot;
                parameters_r <= current_parameters;
                balance_percent_r <= current_balance_percent;
                record_r <= 512'd0;
                status_r <= 4'd0;
            end
            if (codec_valid && (current_state == STATE_WAIT_RECORD_CODEC))
            begin
                record_r <= codec_record;
                parameters_r <= codec_parameters;
                balance_percent_r <= codec_balance_percent;
                if (codec_status != 3'd0) status_r <= {1'b0, codec_status} + 4'd2;
            end
            if (storage_in_valid && (current_state == STATE_WAIT_STORAGE_RESPONSE))
            begin
                record_r <= storage_in_data;
                if (storage_in_status != 3'd0)
                    status_r <= (storage_in_status == 3'd1) ? 4'd1 : 4'd2;
            end
        end
    end
endmodule
