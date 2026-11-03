/**
 * 整机测试输入帧汇合：四组驱动独立握手，任一组更新即提交完整UI快照。
 * 琴键/压力、按钮、弯音和旋钮按压均为状态，未更新时沿用最近值；旋转是一次性事件。
 * out_valid && !out_ready时所有字段保持；背压传给驱动，保留键盘FIFO中的触摸边沿。
 * 接收新帧时仅使用本次真正握手的旋转事件，不能重复沿用上一帧的knob_states。
 * 同拍多源更新一起锁存；各源无需等待其他源valid，慢速ADC不会堵住旋钮/按钮。
 */
module test_full_system_inputs
(
    input clk_sys,
    input rst_n,
    input [23:0] key_states,
    input [15:0] key_velocity [23:0],
    input keyboard_valid,
    output keyboard_ready,
    input [7:0] knob_states,
    input [7:0] knob_dirs,
    input [7:0] knob_pressed,
    input knob_valid,
    output knob_ready,
    input [3:0] button_states,
    input button_valid,
    output button_ready,
    input [15:0] bend_value,
    input bend_valid,
    output bend_ready,
    output [23:0] out_keys,
    output [15:0] out_velocity [23:0],
    output [7:0] out_knob_states,
    output [7:0] out_knob_dirs,
    output [7:0] out_knob_pressed,
    output [3:0] out_buttons,
    output [15:0] out_bend,
    output out_valid,
    input out_ready
);
    reg [23:0] keys_r;
    reg [15:0] velocity_r [23:0];
    reg [7:0] knob_states_r, knob_dirs_r, knob_pressed_r;
    reg [3:0] buttons_r;
    reg [15:0] bend_r;
    reg valid_r;
    wire can_accept = rst_n && (!valid_r || out_ready);
    wire any_valid = keyboard_valid || knob_valid || button_valid || bend_valid;
    integer index;
    genvar lane;

    assign keyboard_ready = can_accept;
    assign knob_ready = can_accept;
    assign button_ready = can_accept;
    assign bend_ready = can_accept;
    assign out_keys = keys_r;
    assign out_knob_states = knob_states_r;
    assign out_knob_dirs = knob_dirs_r;
    assign out_knob_pressed = knob_pressed_r;
    assign out_buttons = buttons_r;
    assign out_bend = bend_r;
    assign out_valid = valid_r;
    generate
        for (lane = 0; lane < 24; lane = lane + 1)
        begin : g_velocity
            assign out_velocity[lane] = velocity_r[lane];
        end
    endgenerate

    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            keys_r <= 24'd0;
            knob_states_r <= 8'd0;
            knob_dirs_r <= 8'd0;
            knob_pressed_r <= 8'd0;
            buttons_r <= 4'd0;
            bend_r <= 16'h8000;
            valid_r <= 1'b0;
            for (index = 0; index < 24; index = index + 1)
                velocity_r[index] <= 16'd0;
        end
        else if (can_accept)
        begin
            valid_r <= any_valid;
            if (any_valid)
            begin
                knob_states_r <= knob_valid ? knob_states : 8'd0;
                if (keyboard_valid)
                begin
                    keys_r <= key_states;
                    for (index = 0; index < 24; index = index + 1)
                        velocity_r[index] <= key_velocity[index];
                end
                if (knob_valid)
                begin
                    knob_dirs_r <= knob_dirs;
                    knob_pressed_r <= knob_pressed;
                end
                if (button_valid)
                    buttons_r <= button_states;
                if (bend_valid)
                    bend_r <= bend_value;
            end
        end
    end
endmodule
