/**
 * 无符号定点数标准化模块
 * 按照指定 Q 格式转化无符号定点数
 */


 /** 无符号定点数标准化
 * in: 输入数据，UQ(QII).(QIF)
 * out: 输出数据，UQ(QOI).(QOF)
 */
module unsigned_fp_norm
#(
    parameter QII = 8,
    parameter QIF = 8,
    parameter QOI = 8,
    parameter QOF = 8
)(
    input [QII+QIF-1:0] in,
    output [QOI+QOF-1:0] out
);
    localparam QMI = QII > QOI ? QII : QOI;
    wire [QMI+QIF-1:0] widened;
    assign widened = { {(QMI-QII){1'b0}}, in };

    wire [QMI+QOF-1:0] norm_frac;
    generate
        if (QIF > QOF)
        begin
            unsigned_rnd #(
                .DW_IN(QMI + QIF),
                .DW_OUT(QMI + QOF)
            ) rnd_u (
                .in(widened),
                .out(norm_frac)
            );
        end
        else if (QIF < QOF)
        begin
            assign norm_frac = {widened, {(QOF - QIF){1'b0}}};
        end
        else
            assign norm_frac = widened;
    endgenerate

    generate
        if (QMI > QOI)
        begin
            unsigned_sat #(
                .DW_IN(QMI + QOF),
                .DW_OUT(QOI + QOF)
            ) sat_u (
                .in(norm_frac),
                .out(out)
            );
        end
        else
        begin
            assign out = norm_frac;
        end
    endgenerate
endmodule


/** 无符号数据四舍五入模块
 * in: 输入数据，位宽为DW_IN
 * out: 输出数据，位宽为DW_OUT
 */
module unsigned_rnd
#(
    parameter DW_IN = 16,  // 输入数据位宽
    parameter DW_OUT = 8   // 输出数据位宽
)(
    input [DW_IN-1:0] in,
    output [DW_OUT-1:0] out
);
    reg [DW_OUT-1:0] out_reg;
    always @(*)
    begin
        if (in[DW_IN-1:DW_IN-DW_OUT] == {{DW_OUT}{1'b1}})
        begin
            out_reg = in[DW_IN-1:DW_IN-DW_OUT];
        end
        else
        begin
            out_reg = in[DW_IN-1:DW_IN-DW_OUT] + in[DW_IN-DW_OUT-1];
        end
    end

    assign out = out_reg;
endmodule

/** 无符号数据饱和模块
 * in: 输入数据，位宽为DW_IN
 * out: 输出数据，位宽为DW_OUT
 */
module unsigned_sat
#(
    parameter DW_IN = 16,
    parameter DW_OUT = 8
)(
    input [DW_IN-1:0] in,
    output [DW_OUT-1:0] out
);
    reg [DW_OUT-1:0] out_reg;
    always @(*)
    begin
        if (in[DW_IN-1:DW_OUT] == {{DW_IN-DW_OUT}{1'b0}})
        begin
            out_reg = in[DW_OUT-1:0];
        end
        else
        begin
            out_reg = {DW_OUT{1'b1}};
        end
    end

    assign out = out_reg;
endmodule
