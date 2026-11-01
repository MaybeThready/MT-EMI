/**
 * Independent UI display publisher, V2: 32-bit sequence + 496-bit model.
 * clk_sys/rst_n: common system clock / rst_sys_n. No Q conversion here.
 * model_commit is a one-cycle internal notification, never waits for ready.
 * model_payload = state[527:32]; activity/reset bits are events to OR when
 * coalescing unsent models. All other fields retain the latest complete state.
 * out_valid && out_ready transfers one 528-bit snapshot. While stalled both
 * valid and the entire snapshot remain stable. Display cannot stall UI/audio.
 * The owner supplies the initial default model after reset (no zero model).
 */
module ui_display_snapshot
#(
    parameter [31:0] INITIAL_SEQ = 32'd0
)(
    input clk_sys,
    input rst_n,
    input model_commit,
    input [495:0] model_payload,
    output [527:0] out_state,
    output out_valid,
    input out_ready
);
    reg [527:0] pending_r, pending_next;
    reg [495:0] latest_r, latest_next;
    reg [31:0] latest_seq_r, latest_seq_next, next_seq_r, next_seq_next;
    reg pending_valid_r, pending_valid_next, latest_valid_r, latest_valid_next;
    assign out_state = pending_r;
    assign out_valid = pending_valid_r;

    always @(*)
    begin
        pending_next = pending_r;
        pending_valid_next = pending_valid_r;
        latest_next = latest_r;
        latest_seq_next = latest_seq_r;
        latest_valid_next = latest_valid_r;
        next_seq_next = next_seq_r;
        if (!pending_valid_r || out_ready)
        begin
            pending_valid_next = latest_valid_r;
            if (latest_valid_r)
                pending_next = {latest_r, latest_seq_r};
            latest_valid_next = 1'b0;
        end
        if (model_commit)
        begin
            next_seq_next = next_seq_r + 32'd1;
            if ((!pending_valid_r || out_ready) && !latest_valid_r)
            begin
                pending_next = {model_payload, next_seq_r};
                pending_valid_next = 1'b1;
            end
            else
            begin
                latest_next = model_payload;
                // Payload offsets = public state offsets minus sequence32.
                if (latest_valid_next)
                begin
                    latest_next[445:424] = latest_r[445:424] | model_payload[445:424];
                    latest_next[467:446] = latest_r[467:446] | model_payload[467:446];
                end
                latest_seq_next = next_seq_r;
                latest_valid_next = 1'b1;
            end
        end
    end

    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n)
        begin
            pending_r <= 528'd0;
            latest_r <= 496'd0;
            latest_seq_r <= 32'd0;
            next_seq_r <= INITIAL_SEQ;
            pending_valid_r <= 1'b0;
            latest_valid_r <= 1'b0;
        end
        else
        begin
            pending_r <= pending_next;
            pending_valid_r <= pending_valid_next;
            latest_r <= latest_next;
            latest_seq_r <= latest_seq_next;
            latest_valid_r <= latest_valid_next;
            next_seq_r <= next_seq_next;
        end
    end
endmodule
