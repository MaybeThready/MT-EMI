/**
 * 共享24位无符号整数转8位BCD模块，转换耗时24个时钟周期。
 * clk/rst_n连接clk_sys/rst_sys_n；in_valid && in_ready启动一次转换。
 * out_valid及BCD结果保持到out_ready握手；不使用除法器、乘法器或DSP。
 */
module lcd_decimal
(
    input clk, input rst_n,
    input in_valid, output in_ready, input [23:0] binary_value,
    output out_valid, input out_ready, output [31:0] bcd
);
    localparam IDLE=2'd0, CONVERT=2'd1, RESULT=2'd2;
    wire [1:0] state;
    reg [1:0] next_state;
    reg [23:0] shift_r;
    reg [31:0] bcd_r,adjusted;
    reg [4:0] count_r;
    integer i;
    assign in_ready=rst_n && state==IDLE;
    assign out_valid=state==RESULT;
    assign bcd=bcd_r;
    fsm #(.W(2),.INITIAL_STATE(IDLE)) fsm_u(.clk(clk),.rst_n(rst_n),.stn(next_state),.stc(state));
    always @(*)
    begin
        next_state=state;
        case(state)
            IDLE:if(in_valid) next_state=CONVERT;
            CONVERT:if(count_r==5'd23) next_state=RESULT;
            RESULT:if(out_ready) next_state=IDLE;
            default:next_state=IDLE;
        endcase
        adjusted=bcd_r;
        for(i=0;i<8;i=i+1)
        begin
            if(bcd_r[4*i +:4]>=4'd5) adjusted[4*i +:4]=bcd_r[4*i +:4]+4'd3;
        end
    end
    always @(posedge clk or negedge rst_n)
    begin
        if(!rst_n)
        begin
            shift_r<=24'd0;
            bcd_r<=32'd0;
            count_r<=5'd0;
        end
        else
        begin
            if(state==IDLE && in_valid)
            begin
                shift_r<=binary_value;
                bcd_r<=32'd0;
                count_r<=5'd0;
            end
            if(state==CONVERT)
            begin
                bcd_r<={adjusted[30:0],shift_r[23]};
                shift_r<={shift_r[22:0],1'b0};
                count_r<=count_r+5'd1;
            end
        end
    end
endmodule
