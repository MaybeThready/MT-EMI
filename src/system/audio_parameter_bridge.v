/**
 * 同一 UI 音频命令的 Mixer 参数随 Channel Rack 事务锁存。
 * UI→机架接收后保持参数，直到机架结果被 Mixer 接收；所有传输均按 valid/ready。
 */
module audio_parameter_bridge
#(parameter PARAM_WIDTH = 280)(
    input clk_sys,
    input rst_n,
    input [PARAM_WIDTH-1:0] ui_parameters,
    output [PARAM_WIDTH-1:0] mixer_parameters,
    input ui_out_valid,
    output ui_out_ready,
    output rack_in_valid,
    input rack_in_ready,
    input rack_out_valid,
    output rack_out_ready,
    output mixer_in_valid,
    input mixer_in_ready
);
    reg [PARAM_WIDTH-1:0] parameters_r;
    reg busy_r;
    assign mixer_parameters = parameters_r;
    assign ui_out_ready = rack_in_ready && !busy_r;
    assign rack_in_valid = ui_out_valid && !busy_r;
    assign mixer_in_valid = rack_out_valid && busy_r;
    assign rack_out_ready = mixer_in_ready && busy_r;

    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            parameters_r <= '0;
            busy_r <= 1'b0;
        end
        else
        begin
            if (rack_out_valid && rack_out_ready)
                busy_r <= 1'b0;
            if (ui_out_valid && ui_out_ready)
            begin
                parameters_r <= ui_parameters;
                busy_r <= 1'b1;
            end
        end
    end
endmodule
