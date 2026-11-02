/**
 * 2026-11-02 S2和弦扩展：play_mode=0单音，=1根音/大三度/纯五度，偏移0/4/7。
 * 输入物理press_event/release_event；输出tone_count[k]=0/1/3，
 * tone_note[3*k+t]为7位MIDI音高，根音60+k，KEY_NUM=1..24。
 * 松键原样传递，不按新模式重算旧音，不分配声部，不合并同音。
 * clk_sys上升沿valid&&ready接收；锁存整帧，背压保持；rst_n同音频。
 */
module chord_note_expander
#(parameter KEY_NUM=24)(
    input clk_sys, input rst_n, input play_mode,
    input [KEY_NUM-1:0] press_event, input [KEY_NUM-1:0] release_event,
    input in_valid, output in_ready,
    output [KEY_NUM-1:0] out_press_event, output [KEY_NUM-1:0] out_release_event,
    output [1:0] tone_count [KEY_NUM-1:0],
    output [6:0] tone_note [3*KEY_NUM-1:0],
    output out_valid, input out_ready
);
    reg pending_r;
    reg [KEY_NUM-1:0] press_r, release_r;
    reg [1:0] count_r [KEY_NUM-1:0];
    reg [6:0] note_r [3*KEY_NUM-1:0];
    integer k;
    genvar g;
    assign in_ready=rst_n && !pending_r;
    assign out_valid=pending_r;
    assign out_press_event=press_r;
    assign out_release_event=release_r;
    generate
        for(g=0;g<KEY_NUM;g=g+1)
        begin : key_outputs
            assign tone_count[g]=count_r[g];
            assign tone_note[3*g]=note_r[3*g];
            assign tone_note[3*g+1]=note_r[3*g+1];
            assign tone_note[3*g+2]=note_r[3*g+2];
        end
    endgenerate
    always @(posedge clk_sys or negedge rst_n)
    begin
        if(!rst_n)
        begin
            pending_r<=1'b0; press_r<='0; release_r<='0;
            for(k=0;k<KEY_NUM;k=k+1)
            begin
                count_r[k]<=2'd0;
                note_r[3*k]<=7'd0; note_r[3*k+1]<=7'd0; note_r[3*k+2]<=7'd0;
            end
        end
        else
        begin
            if(out_valid && out_ready) pending_r<=1'b0;
            if(in_valid && in_ready)
            begin
                pending_r<=1'b1; press_r<=press_event; release_r<=release_event;
                for(k=0;k<KEY_NUM;k=k+1)
                begin
                    count_r[k]<=press_event[k] ? (play_mode ? 2'd3 : 2'd1) : 2'd0;
                    note_r[3*k]<=press_event[k] ? 7'd60+k : 7'd0;
                    note_r[3*k+1]<=(press_event[k] && play_mode) ? 7'd64+k : 7'd0;
                    note_r[3*k+2]<=(press_event[k] && play_mode) ? 7'd67+k : 7'd0;
                end
            end
        end
    end
endmodule
