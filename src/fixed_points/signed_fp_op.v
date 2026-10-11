/**
 * 有符号定点数四则运算模块
 * 以固定一拍延时进行有符号定点数的四则运算
 */


/** 有符号定点数加法
 * clk: 时钟信号
 * rst_n: 复位信号，低电平有效
 * in_a: 输入数据A，SQ(QII_A).(QIF_A)
 * in_b: 输入数据B，SQ(QII_B).(QIF_B)
 * out: 输出数据A+B，SQ(QOI).(QOF)
 */
module signed_fp_add
#(
    parameter QII_A = 8,
    parameter QIF_A = 8,
    parameter QII_B = QII_A,
    parameter QIF_B = QIF_A,
    parameter QOI = QII_A,
    parameter QOF = QIF_A
)
(
    input clk, rst_n,
    input signed [QII_A+QIF_A-1:0] in_a,
    input signed [QII_B+QIF_B-1:0] in_b,
    output signed [QOI+QOF-1:0] out
);
    localparam QRI = (QII_A > QII_B ? QII_A : QII_B) + 1;
    localparam QRF = QIF_A > QIF_B ? QIF_A : QIF_B;
    reg signed [QRI+QRF-1:0] result;

    wire signed [QRI+QRF-1:0] a;
    wire signed [QRI+QRF-1:0] b;

    signed_fp_norm #(
        .QII(QII_A),
        .QIF(QIF_A),
        .QOI(QRI),
        .QOF(QRF)
    ) norm_a_u (
        .in(in_a),
        .out(a)
    );

    signed_fp_norm #(
        .QII(QII_B),
        .QIF(QIF_B),
        .QOI(QRI),
        .QOF(QRF)
    ) norm_b_u (
        .in(in_b),
        .out(b)
    );
    
    always @(posedge clk or negedge rst_n)
    begin
        if (!rst_n)
        begin
            result <= '0;
        end
        else
        begin
            result <= a + b;
        end
    end

    signed_fp_norm #(
        .QII(QRI),
        .QIF(QRF),
        .QOI(QOI),
        .QOF(QOF)
    ) norm_u (
        .in(result),
        .out(out)
    );
endmodule

/** 有符号定点数减法
 * clk: 时钟信号
 * rst_n: 复位信号，低电平有效
 * in_a: 输入数据A，SQ(QII_A).(QIF_A)
 * in_b: 输入数据B，SQ(QII_B).(QIF_B)
 * out: 输出数据A-B，SQ(QOI).(QOF)
 */
module signed_fp_sub
#(
    parameter QII_A = 8,
    parameter QIF_A = 8,
    parameter QII_B = QII_A,
    parameter QIF_B = QIF_A,
    parameter QOI = QII_A,
    parameter QOF = QIF_A
)
(
    input clk, rst_n,
    input signed [QII_A+QIF_A-1:0] in_a,
    input signed [QII_B+QIF_B-1:0] in_b,
    output signed [QOI+QOF-1:0] out
);
    localparam QRI = QII_A > QII_B ? QII_A : QII_B;
    localparam QRF = QIF_A > QIF_B ? QIF_A : QIF_B;
    reg signed [QRI+QRF-1:0] result;

    wire signed [QRI+QRF-1:0] a;
    wire signed [QRI+QRF-1:0] b;

    signed_fp_norm #(
        .QII(QII_A),
        .QIF(QIF_A),
        .QOI(QRI),
        .QOF(QRF)
    ) norm_a_u (
        .in(in_a),
        .out(a)
    );

    signed_fp_norm #(
        .QII(QII_B),
        .QIF(QIF_B),
        .QOI(QRI),
        .QOF(QRF)
    ) norm_b_u (
        .in(in_b),
        .out(b)
    );

    always @(posedge clk or negedge rst_n)
    begin
        if (!rst_n)
        begin
            result <= '0;
        end
        else
        begin
            result <= a - b;
        end
    end

    signed_fp_norm #(
        .QII(QRI),
        .QIF(QRF),
        .QOI(QOI),
        .QOF(QOF)
    ) norm_u (
        .in(result),
        .out(out)
    );
endmodule

/** 有符号定点数乘法
 * clk: 时钟信号
 * rstn: 复位信号，低电平有效
 * in_a: 输入数据A，SQ(QII_A).(QIF_A)
 * in_b: 输入数据B，SQ(QII_B).(QIF_B)
 * out: 输出数据A*B，SQ(QOI).(QOF)
 */
module signed_fp_mult
#(
    parameter QII_A = 8,
    parameter QIF_A = 8,
    parameter QII_B = QII_A,
    parameter QIF_B = QIF_A,
    parameter QOI = QII_A,
    parameter QOF = QIF_A
)
(
    input clk, rst_n,
    input signed [QII_A+QIF_A-1:0] in_a,
    input signed [QII_B+QIF_B-1:0] in_b,
    output signed [QOI+QOF-1:0] out
);
    localparam QRI = QII_A + QII_B;
    localparam QRF = QIF_A + QIF_B;
    reg signed [QRI+QRF-1:0] result;

    always @(posedge clk or negedge rst_n)
    begin
        if (!rst_n)
        begin
            result <= '0;
        end
        else
        begin
            result <= in_a * in_b;
        end
    end

    signed_fp_norm #(
        .QII(QRI),
        .QIF(QRF),
        .QOI(QOI),
        .QOF(QOF)
    ) norm_u (
        .in(result),
        .out(out)
    );
endmodule

/** 有符号定点数除法
 * clk: 时钟信号
 * rstn: 复位信号，低电平有效
 * in_a: 输入数据A，SQ(QII_A).(QIF_A)
 * in_b: 输入数据B，SQ(QII_B).(QIF_B)
 * out: 输出数据A/B，SQ(QOI).(QOF)
 */
module signed_fp_div
#(
    parameter QII_A = 8,
    parameter QIF_A = 8,
    parameter QII_B = QII_A,
    parameter QIF_B = QIF_A,
    parameter QOI = QII_A,
    parameter QOF = QIF_A
)
(
    input clk, rst_n,
    input signed [QII_A+QIF_A-1:0] in_a,
    input signed [QII_B+QIF_B-1:0] in_b,
    output signed [QOI+QOF-1:0] out
);
    localparam QRI = QII_A + QIF_B + 1;
    localparam QRF = (QIF_A + QII_B > QOF) ? (QIF_A + QII_B) : (QOF + 1);

    wire signed [QRI+QRF-1:0] a;
    wire signed [QRI+QRF-1:0] b;
    reg signed [QRI+QRF-1:0] result;

    signed_fp_norm #(
        .QII(QII_A),
        .QIF(QIF_A),
        .QOI(QII_A + 1),
        .QOF(QRF + QIF_B)
    ) norm_a_u (
        .in(in_a),
        .out(a)
    );

    signed_fp_norm #(
        .QII(QII_B),
        .QIF(QIF_B),
        .QOI(QRI + QRF - QIF_B),
        .QOF(QIF_B)
    ) norm_b_u (
        .in(in_b),
        .out(b)
    );

    always @(posedge clk or negedge rst_n)
    begin
        if (!rst_n)
        begin
            result <= '0;
        end
        else if (b == '0)
        begin
            result <= '0;
        end
        else
        begin
            result <= a / b;
        end
    end

    signed_fp_norm #(
        .QII(QRI),
        .QIF(QRF),
        .QOI(QOI),
        .QOF(QOF)
    ) norm_u (
        .in(result),
        .out(out)
    );
endmodule
