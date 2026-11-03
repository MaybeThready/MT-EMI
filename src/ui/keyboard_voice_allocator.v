/**
 * 2026-11-02 S2：每个物理键原子分配1/3声部；tone_count[k]=0/1/3，tone_note[3*k+t]
 * 为7位MIDI音高。key_id保留物理压力/松键归属，新增note_number独立存音高。
 * 先松后按，键号递增；扫描一次保留前三候选：低号空闲/最老释放/最老按住。
 * 本帧已提交声部不可再次抢占；不足整组跳过；内部逐音写入，整帧完成才公开。
 * 候选读取/比较分拍，年龄读取/更新分拍；新音只发on并清旧off，旧键不能误释放。
 * out_ready须是音频真正交付；note_busy_valid须是对应命令的反馈，在WAIT_EVENT
 * 送一次，逐路回收!held&&!busy，feedback_done单拍后才可开始新分配。
 * 所有握手在clk_sys上升沿；背压冻结输出；rst_n与音频共同复位。
 */
module keyboard_voice_allocator
#(
    parameter KEY_NUM=24,
    parameter MAX_POLYPHONY=32,
    parameter KEY_ID_WIDTH=(KEY_NUM>1) ? $clog2(KEY_NUM) : 1
)(
    input clk_sys, input rst_n,
    input [KEY_NUM-1:0] press_event, input [KEY_NUM-1:0] release_event,
    input [1:0] tone_count [KEY_NUM-1:0],
    input [6:0] tone_note [3*KEY_NUM-1:0],
    input [MAX_POLYPHONY-1:0] note_busy, input note_busy_valid,
    output feedback_done, input in_valid, output in_ready,
    output [MAX_POLYPHONY-1:0] note_on, output [MAX_POLYPHONY-1:0] note_off,
    output [KEY_ID_WIDTH-1:0] key_id [MAX_POLYPHONY-1:0],
    output [6:0] note_number [MAX_POLYPHONY-1:0],
    output [MAX_POLYPHONY-1:0] occupied, output [MAX_POLYPHONY-1:0] held,
    output out_valid, input out_ready
);
    localparam V=(MAX_POLYPHONY>1) ? $clog2(MAX_POLYPHONY) : 1;
    localparam C=$clog2(MAX_POLYPHONY+1);
    localparam WAIT_EVENT=4'd0, RELEASE_KEYS=4'd1, CHECK_KEY=4'd2,
        SEARCH=4'd3, DRAIN=4'd4, CHECK_GROUP=4'd5, READ_AGE=4'd6,
        ASSIGN_TONE=4'd7, NEXT_KEY=4'd8, CAPTURE=4'd9, WAIT_AUDIO=4'd10, RECLAIM=4'd11;
    wire [3:0] stc;
    reg [3:0] stn;
    reg [KEY_NUM-1:0] press_r, release_r;
    reg [1:0] counts_r [KEY_NUM-1:0];
    reg [6:0] tones_r [3*KEY_NUM-1:0];
    reg [KEY_ID_WIDTH-1:0] key_index_r;
    reg [V-1:0] voice_index_r, selected_age_r;
    reg [1:0] tone_index_r, required_r;
    reg [MAX_POLYPHONY-1:0] allocated_r, held_r, reserved_r, busy_r;
    reg [C-1:0] reserved_count_r;
    reg [KEY_ID_WIDTH-1:0] owner_r [MAX_POLYPHONY-1:0];
    reg [6:0] pitch_r [MAX_POLYPHONY-1:0];
    reg [V-1:0] age_r [MAX_POLYPHONY-1:0];
    reg [V-1:0] winner_voice_r [0:2], winner_age_r [0:2];
    reg [1:0] winner_class_r [0:2];
    reg [2:0] winner_valid_r;
    reg candidate_valid_r;
    reg [V-1:0] candidate_voice_r, candidate_age_r;
    reg [1:0] candidate_class_r;
    reg [MAX_POLYPHONY-1:0] on_r, off_r, occupied_r, held_out_r;
    reg [KEY_ID_WIDTH-1:0] owner_out_r [MAX_POLYPHONY-1:0];
    reg [6:0] pitch_out_r [MAX_POLYPHONY-1:0];
    reg feedback_done_r;
    wire [V-1:0] selected_voice=winner_voice_r[tone_index_r];
    wire group_fits=(counts_r[key_index_r]==2'd1 || counts_r[key_index_r]==2'd3)
        && (counts_r[key_index_r]<=MAX_POLYPHONY-reserved_count_r);
    wire group_complete=(required_r==2'd1) ? winner_valid_r[0] : (&winner_valid_r);
    integer i;
    genvar g;
    function better;
        input valid_old;
        input [1:0] class_old;
        input [V-1:0] age_old, voice_old;
        begin
            better=!valid_old || candidate_class_r<class_old ||
                (candidate_class_r==class_old &&
                 ((candidate_class_r!=2'd0 && candidate_age_r>age_old) ||
                  ((candidate_class_r==2'd0 || candidate_age_r==age_old) && candidate_voice_r<voice_old)));
        end
    endfunction
    assign in_ready=rst_n && stc==WAIT_EVENT && !note_busy_valid;
    assign out_valid=stc==WAIT_AUDIO;
    assign note_on=on_r;
    assign note_off=off_r;
    assign occupied=occupied_r;
    assign held=held_out_r;
    assign feedback_done=feedback_done_r;
    generate
        for(g=0;g<MAX_POLYPHONY;g=g+1)
        begin : outputs_and_events
            assign key_id[g]=owner_out_r[g];
            assign note_number[g]=pitch_out_r[g];
            always @(posedge clk_sys or negedge rst_n)
            begin
                if(!rst_n)
                begin
                    on_r[g]<=1'b0; off_r[g]<=1'b0;
                end
                else if(stc==WAIT_AUDIO && out_ready)
                begin
                    on_r[g]<=1'b0; off_r[g]<=1'b0;
                end
                else if(stc==ASSIGN_TONE && selected_voice==g)
                begin
                    on_r[g]<=1'b1; off_r[g]<=1'b0;
                end
                else if(stc==RELEASE_KEYS && voice_index_r==g && allocated_r[g]
                    && held_r[g] && release_r[owner_r[g]]) off_r[g]<=1'b1;
            end
        end
    endgenerate
    fsm #(.W(4),.INITIAL_STATE(WAIT_EVENT)) fsm_u (
        .clk(clk_sys),.rst_n(rst_n),.stn(stn),.stc(stc)
    );
    always @(*)
    begin
        stn=stc;
        case(stc)
            WAIT_EVENT:
                if(note_busy_valid) stn=RECLAIM;
                else if(in_valid) stn=RELEASE_KEYS;
            RECLAIM: if(voice_index_r==MAX_POLYPHONY-1) stn=WAIT_EVENT;
            RELEASE_KEYS: if(voice_index_r==MAX_POLYPHONY-1) stn=CHECK_KEY;
            CHECK_KEY: stn=(press_r[key_index_r] && group_fits) ? SEARCH : NEXT_KEY;
            SEARCH: if(voice_index_r==MAX_POLYPHONY-1) stn=DRAIN;
            DRAIN: stn=CHECK_GROUP;
            CHECK_GROUP: stn=group_complete ? READ_AGE : NEXT_KEY;
            READ_AGE: stn=ASSIGN_TONE;
            ASSIGN_TONE: stn=(tone_index_r+2'd1==required_r) ? NEXT_KEY : READ_AGE;
            NEXT_KEY: stn=(key_index_r==KEY_NUM-1) ? CAPTURE : CHECK_KEY;
            CAPTURE: stn=WAIT_AUDIO;
            WAIT_AUDIO: if(out_ready) stn=WAIT_EVENT;
            default: stn=WAIT_EVENT;
        endcase
    end
    always @(posedge clk_sys or negedge rst_n)
    begin
        if(!rst_n)
        begin
            press_r<='0; release_r<='0; key_index_r<='0; voice_index_r<='0;
            tone_index_r<=2'd0; required_r<=2'd0; allocated_r<='0; held_r<='0;
            reserved_r<='0; reserved_count_r<='0; busy_r<='0; selected_age_r<='0;
            winner_valid_r<=3'd0; candidate_valid_r<=1'b0; candidate_voice_r<='0;
            candidate_age_r<='0; candidate_class_r<=2'd0; occupied_r<='0;
            held_out_r<='0; feedback_done_r<=1'b0;
            for(i=0;i<KEY_NUM;i=i+1) counts_r[i]<=2'd0;
            for(i=0;i<3*KEY_NUM;i=i+1) tones_r[i]<=7'd0;
            for(i=0;i<3;i=i+1)
            begin
                winner_voice_r[i]<='0; winner_age_r[i]<='0; winner_class_r[i]<=2'd0;
            end
            for(i=0;i<MAX_POLYPHONY;i=i+1)
            begin
                owner_r[i]<='0; pitch_r[i]<=7'd0; age_r[i]<=i;
                owner_out_r[i]<='0; pitch_out_r[i]<=7'd0;
            end
        end
        else
        begin
            feedback_done_r<=1'b0;
            case(stc)
                WAIT_EVENT:
                begin
                    if(note_busy_valid)
                    begin
                        busy_r<=note_busy; voice_index_r<='0;
                    end
                    else if(in_valid && in_ready)
                    begin
                        press_r<=press_event; release_r<=release_event;
                        reserved_r<='0; reserved_count_r<='0; key_index_r<='0; voice_index_r<='0;
                        for(i=0;i<KEY_NUM;i=i+1) counts_r[i]<=tone_count[i];
                        for(i=0;i<3*KEY_NUM;i=i+1) tones_r[i]<=tone_note[i];
                    end
                end
                RECLAIM:
                begin
                    for(i=0;i<MAX_POLYPHONY;i=i+1)
                        if(voice_index_r==i && allocated_r[i] && !held_r[i] && !busy_r[i])
                        begin
                            allocated_r[i]<=1'b0; occupied_r[i]<=1'b0;
                            owner_r[i]<='0; owner_out_r[i]<='0; pitch_r[i]<=7'd0; pitch_out_r[i]<=7'd0;
                        end
                    if(voice_index_r==MAX_POLYPHONY-1) feedback_done_r<=1'b1;
                    else voice_index_r<=voice_index_r+1'b1;
                end
                RELEASE_KEYS:
                begin
                    for(i=0;i<MAX_POLYPHONY;i=i+1)
                        if(voice_index_r==i && allocated_r[i] && held_r[i] && release_r[owner_r[i]]) held_r[i]<=1'b0;
                    if(voice_index_r!=MAX_POLYPHONY-1) voice_index_r<=voice_index_r+1'b1;
                end
                CHECK_KEY:
                begin
                    voice_index_r<='0; winner_valid_r<=3'd0; candidate_valid_r<=1'b0;
                    required_r<=counts_r[key_index_r]; tone_index_r<=2'd0;
                end
                SEARCH,DRAIN:
                begin
                    if(candidate_valid_r)
                    begin
                        if(better(winner_valid_r[0],winner_class_r[0],winner_age_r[0],winner_voice_r[0]))
                        begin
                            winner_valid_r<={winner_valid_r[1:0],1'b1};
                            winner_voice_r[2]<=winner_voice_r[1]; winner_age_r[2]<=winner_age_r[1]; winner_class_r[2]<=winner_class_r[1];
                            winner_voice_r[1]<=winner_voice_r[0]; winner_age_r[1]<=winner_age_r[0]; winner_class_r[1]<=winner_class_r[0];
                            winner_voice_r[0]<=candidate_voice_r; winner_age_r[0]<=candidate_age_r; winner_class_r[0]<=candidate_class_r;
                        end
                        else if(better(winner_valid_r[1],winner_class_r[1],winner_age_r[1],winner_voice_r[1]))
                        begin
                            winner_valid_r[2:1]<={winner_valid_r[1],1'b1};
                            winner_voice_r[2]<=winner_voice_r[1]; winner_age_r[2]<=winner_age_r[1]; winner_class_r[2]<=winner_class_r[1];
                            winner_voice_r[1]<=candidate_voice_r; winner_age_r[1]<=candidate_age_r; winner_class_r[1]<=candidate_class_r;
                        end
                        else if(better(winner_valid_r[2],winner_class_r[2],winner_age_r[2],winner_voice_r[2]))
                        begin
                            winner_valid_r[2]<=1'b1;
                            winner_voice_r[2]<=candidate_voice_r; winner_age_r[2]<=candidate_age_r; winner_class_r[2]<=candidate_class_r;
                        end
                    end
                    if(stc==SEARCH)
                    begin
                        candidate_valid_r<=!reserved_r[voice_index_r];
                        candidate_voice_r<=voice_index_r; candidate_age_r<=age_r[voice_index_r];
                        candidate_class_r<=!allocated_r[voice_index_r] ? 2'd0 : (!held_r[voice_index_r] ? 2'd1 : 2'd2);
                        if(voice_index_r!=MAX_POLYPHONY-1) voice_index_r<=voice_index_r+1'b1;
                    end
                    else candidate_valid_r<=1'b0;
                end
                READ_AGE: selected_age_r<=age_r[selected_voice];
                ASSIGN_TONE:
                begin
                    for(i=0;i<MAX_POLYPHONY;i=i+1)
                        if(selected_voice==i)
                        begin
                            owner_r[i]<=key_index_r; pitch_r[i]<=tones_r[3*key_index_r+tone_index_r];
                            allocated_r[i]<=1'b1; held_r[i]<=1'b1; reserved_r[i]<=1'b1; age_r[i]<='0;
                        end
                        else if(age_r[i]<selected_age_r) age_r[i]<=age_r[i]+1'b1;
                    reserved_count_r<=reserved_count_r+1'b1;
                    if(tone_index_r+2'd1!=required_r) tone_index_r<=tone_index_r+2'd1;
                end
                NEXT_KEY: if(key_index_r!=KEY_NUM-1) key_index_r<=key_index_r+1'b1;
                CAPTURE:
                begin
                    occupied_r<=allocated_r; held_out_r<=held_r;
                    for(i=0;i<MAX_POLYPHONY;i=i+1)
                    begin
                        owner_out_r[i]<=owner_r[i]; pitch_out_r[i]<=pitch_r[i];
                    end
                end
                default: ;
            endcase
        end
    end
    // synthesis translate_off
    initial
    begin
        if(KEY_NUM<1 || KEY_NUM>24 || MAX_POLYPHONY<1) $fatal(1,"invalid voice allocator configuration");
    end
    // synthesis translate_on
endmodule
