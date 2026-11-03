/**
 * 独立外设帧汇合：以旋钮帧为节拍，将最近的键盘、按键和弯音状态送给 UI。
 * 键盘/按键各保留一个尚未交付的状态帧；旋钮 valid/ready 背压保留转动事件。
 * 弯音是连续位置量，取最近一次已交付值，未取得首样时使用中心值。
 * 所有输出在 in_valid && !in_ready 期间保持，复位后须先收到键盘和按键帧。
 */
module ui_peripheral_bridge
#(parameter KEY_NUM = 24)(
    input clk_sys,
    input rst_n,
    input [KEY_NUM-1:0] keyboard_states,
    input [15:0] keyboard_velocity [KEY_NUM-1:0],
    input keyboard_valid,
    output keyboard_ready,
    input [3:0] button_states,
    input button_valid,
    output button_ready,
    input [7:0] knob_states,
    input [7:0] knob_dirs,
    input [7:0] knob_pressed,
    input knob_valid,
    output knob_ready,
    input [15:0] bend_value,
    input bend_valid,
    output bend_ready,
    output [KEY_NUM-1:0] key_frame,
    output [15:0] velocity_frame [KEY_NUM-1:0],
    output [3:0] button_frame,
    output [7:0] knob_states_frame,
    output [7:0] knob_dirs_frame,
    output [7:0] knob_pressed_frame,
    output [15:0] bend_frame,
    output in_valid,
    input in_ready
);
    reg keyboard_seen_r, button_seen_r;
    reg keyboard_pending_r, button_pending_r, frame_full_r;
    reg [KEY_NUM-1:0] key_latest_r, key_frame_r;
    reg [15:0] velocity_latest_r [KEY_NUM-1:0];
    reg [15:0] velocity_frame_r [KEY_NUM-1:0];
    reg [3:0] button_latest_r, button_frame_r;
    reg [7:0] knob_states_frame_r, knob_dirs_frame_r, knob_pressed_frame_r;
    reg [15:0] bend_latest_r, bend_frame_r;
    integer key_index;
    genvar g;

    assign keyboard_ready = rst_n && !keyboard_pending_r;
    assign button_ready = rst_n && !button_pending_r;
    assign knob_ready = rst_n && !frame_full_r && keyboard_seen_r && button_seen_r;
    assign bend_ready = rst_n;
    assign in_valid = frame_full_r;
    assign key_frame = key_frame_r;
    assign button_frame = button_frame_r;
    assign knob_states_frame = knob_states_frame_r;
    assign knob_dirs_frame = knob_dirs_frame_r;
    assign knob_pressed_frame = knob_pressed_frame_r;
    assign bend_frame = bend_frame_r;
    generate
        for (g = 0; g < KEY_NUM; g = g + 1)
            assign velocity_frame[g] = velocity_frame_r[g];
    endgenerate

    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            keyboard_seen_r <= 1'b0;
            button_seen_r <= 1'b0;
            keyboard_pending_r <= 1'b0;
            button_pending_r <= 1'b0;
            frame_full_r <= 1'b0;
            key_latest_r <= '0;
            key_frame_r <= '0;
            button_latest_r <= 4'd0;
            button_frame_r <= 4'd0;
            knob_states_frame_r <= 8'd0;
            knob_dirs_frame_r <= 8'd0;
            knob_pressed_frame_r <= 8'd0;
            bend_latest_r <= 16'h8000;
            bend_frame_r <= 16'h8000;
            for (key_index = 0; key_index < KEY_NUM; key_index = key_index + 1)
            begin
                velocity_latest_r[key_index] <= 16'd0;
                velocity_frame_r[key_index] <= 16'd0;
            end
        end
        else
        begin
            if (in_valid && in_ready)
                frame_full_r <= 1'b0;
            if (knob_valid && knob_ready)
            begin
                frame_full_r <= 1'b1;
                keyboard_pending_r <= 1'b0;
                button_pending_r <= 1'b0;
                key_frame_r <= key_latest_r;
                button_frame_r <= button_latest_r;
                knob_states_frame_r <= knob_states;
                knob_dirs_frame_r <= knob_dirs;
                knob_pressed_frame_r <= knob_pressed;
                bend_frame_r <= bend_latest_r;
                for (key_index = 0; key_index < KEY_NUM; key_index = key_index + 1)
                    velocity_frame_r[key_index] <= velocity_latest_r[key_index];
            end
            // 同拍到达的新状态留待下一帧，不能被上述清 pending 覆盖。
            if (keyboard_valid && keyboard_ready)
            begin
                keyboard_seen_r <= 1'b1;
                keyboard_pending_r <= 1'b1;
                key_latest_r <= keyboard_states;
                for (key_index = 0; key_index < KEY_NUM; key_index = key_index + 1)
                    velocity_latest_r[key_index] <= keyboard_velocity[key_index];
            end
            if (button_valid && button_ready)
            begin
                button_seen_r <= 1'b1;
                button_pending_r <= 1'b1;
                button_latest_r <= button_states;
            end
            if (bend_valid && bend_ready)
                bend_latest_r <= bend_value;
        end
    end
endmodule
