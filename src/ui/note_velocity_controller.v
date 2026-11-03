/**
 * 声部力度控制候选：锁存整帧输入，再以一个运算通道逐声部处理。
 * 输出与原模块一致；每声部按读取、计算、提交三拍处理。
 * in_valid && in_ready 锁存输入，out_valid && out_ready 交付结果。
 */
module note_velocity_controller
#(
    parameter KEY_NUM = 24,
    parameter MAX_POLYPHONY = 32,
    parameter KEY_ID_WIDTH = (KEY_NUM > 1) ? $clog2(KEY_NUM) : 1,
    parameter [15:0] MIN_VELOCITY = 16'd3277,
    parameter [15:0] SLEW_STEP = 16'd274
)(
    input clk_sys,
    input rst_n,
    input [KEY_ID_WIDTH-1:0] key_id [MAX_POLYPHONY-1:0],
    input [15:0] key_velocity [KEY_NUM-1:0],
    input [MAX_POLYPHONY-1:0] occupied,
    input [MAX_POLYPHONY-1:0] held,
    input [MAX_POLYPHONY-1:0] note_on,
    input in_valid,
    output in_ready,
    output [15:0] note_velocity [MAX_POLYPHONY-1:0],
    output out_valid,
    input out_ready
);
    localparam INDEX_WIDTH = (MAX_POLYPHONY > 1) ? $clog2(MAX_POLYPHONY) : 1;
    localparam STATE_WAIT_SAMPLE = 3'd0;
    localparam STATE_SELECT = 3'd1;
    localparam STATE_CALCULATE = 3'd2;
    localparam STATE_COMMIT = 3'd3;
    localparam STATE_WAIT_RESULT_ACCEPT = 3'd4;
    localparam signed [16:0] POSITIVE_STEP = $signed({1'b0, SLEW_STEP});
    localparam signed [16:0] NEGATIVE_STEP = -POSITIVE_STEP;

    wire [2:0] current_state;
    reg [2:0] next_state;
    reg [INDEX_WIDTH-1:0] voice_index;
    reg [KEY_ID_WIDTH-1:0] key_id_r [MAX_POLYPHONY-1:0];
    reg [15:0] key_velocity_r [KEY_NUM-1:0];
    reg [MAX_POLYPHONY-1:0] occupied_r, held_r, note_on_r;
    reg [15:0] velocity_r [MAX_POLYPHONY-1:0];
    reg selected_occupied_r, selected_held_r, selected_note_on_r;
    reg [15:0] selected_pressure_r, selected_velocity_r;
    reg [15:0] target_r;
    reg signed [16:0] difference_r;

    wire [KEY_ID_WIDTH-1:0] selected_key = key_id_r[voice_index];
    wire selected_occupied = occupied_r[voice_index] && (selected_key < KEY_NUM);
    wire [15:0] pressure = selected_occupied ? key_velocity_r[selected_key] : 16'd0;
    wire [15:0] target = selected_pressure_r < MIN_VELOCITY ?
                         MIN_VELOCITY : selected_pressure_r;
    wire [15:0] step_delta = difference_r > 0 ? SLEW_STEP : -SLEW_STEP;
    wire [15:0] stepped_velocity = selected_velocity_r + step_delta;

    assign in_ready = rst_n && (current_state == STATE_WAIT_SAMPLE);
    assign out_valid = current_state == STATE_WAIT_RESULT_ACCEPT;

    genvar lane;
    generate
        for (lane = 0; lane < MAX_POLYPHONY; lane = lane + 1)
        begin : output_lanes
            assign note_velocity[lane] = velocity_r[lane];
        end
    endgenerate

    fsm #(.W(3), .INITIAL_STATE(STATE_WAIT_SAMPLE)) fsm_u (
        .clk(clk_sys), .rst_n(rst_n), .stn(next_state), .stc(current_state)
    );

    always @(*)
    begin
        case (current_state)
            STATE_WAIT_SAMPLE: next_state = in_valid ? STATE_SELECT : STATE_WAIT_SAMPLE;
            STATE_SELECT: next_state = STATE_CALCULATE;
            STATE_CALCULATE: next_state = STATE_COMMIT;
            STATE_COMMIT: next_state = voice_index == MAX_POLYPHONY - 1 ?
                STATE_WAIT_RESULT_ACCEPT : STATE_SELECT;
            STATE_WAIT_RESULT_ACCEPT: next_state = out_ready ?
                STATE_WAIT_SAMPLE : STATE_WAIT_RESULT_ACCEPT;
            default: next_state = STATE_WAIT_SAMPLE;
        endcase
    end

    integer voice, key;
    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            voice_index <= '0;
            occupied_r <= '0;
            held_r <= '0;
            note_on_r <= '0;
            selected_occupied_r <= 1'b0;
            selected_held_r <= 1'b0;
            selected_note_on_r <= 1'b0;
            selected_pressure_r <= 16'd0;
            selected_velocity_r <= 16'd0;
            target_r <= 16'd0;
            difference_r <= 17'sd0;
            for (voice = 0; voice < MAX_POLYPHONY; voice = voice + 1)
            begin
                key_id_r[voice] <= '0;
                velocity_r[voice] <= 16'd0;
            end
            for (key = 0; key < KEY_NUM; key = key + 1)
                key_velocity_r[key] <= 16'd0;
        end
        else
        begin
            case (current_state)
                STATE_WAIT_SAMPLE:
                begin
                    if (in_valid)
                    begin
                        voice_index <= '0;
                        occupied_r <= occupied;
                        held_r <= held;
                        note_on_r <= note_on;
                        for (voice = 0; voice < MAX_POLYPHONY; voice = voice + 1)
                            key_id_r[voice] <= key_id[voice];
                        for (key = 0; key < KEY_NUM; key = key + 1)
                            key_velocity_r[key] <= key_velocity[key];
                    end
                end
                STATE_SELECT:
                begin
                    selected_occupied_r <= selected_occupied;
                    selected_held_r <= held_r[voice_index];
                    selected_note_on_r <= note_on_r[voice_index];
                    selected_pressure_r <= pressure;
                    selected_velocity_r <= velocity_r[voice_index];
                end
                STATE_CALCULATE:
                begin
                    target_r <= target;
                    difference_r <= $signed({1'b0, target}) -
                                    $signed({1'b0, selected_velocity_r});
                end
                STATE_COMMIT:
                begin
                    if (!selected_occupied_r)
                        velocity_r[voice_index] <= 16'd0;
                    else if (selected_note_on_r)
                        velocity_r[voice_index] <= target_r;
                    else if (selected_held_r)
                    begin
                        if (difference_r > POSITIVE_STEP || difference_r < NEGATIVE_STEP)
                            velocity_r[voice_index] <= stepped_velocity;
                        else
                            velocity_r[voice_index] <= target_r;
                    end
                    if (voice_index != MAX_POLYPHONY - 1)
                        voice_index <= voice_index + 1'b1;
                end
                default: ;
            endcase
        end
    end

    // synthesis translate_off
    initial
    begin
        if ((KEY_NUM < 1) || (MAX_POLYPHONY < 1) || (SLEW_STEP == 16'd0))
            $fatal(1, "非法力度配置");
    end
    // synthesis translate_on
endmodule
