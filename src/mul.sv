// ============================================================================
// 32 x 32 EX1/EX2 两级流水乘法器的乘积级
//
// EX1 的 mul_src1/mul_src2 已经是专用、无复位的 A/B 输入寄存器；本模块
// 只实现 EX2 的乘积 P 寄存器。于是 M0 在 EX1、M1 紧随其后时，可以在
// 同一边沿消费 M0 的 P 结果并锁存 M1 的新乘积，稳态启动间隔为一拍。
// 乘积寄存器不带复位，便于 Vivado 吸收到 DSP48E1 内部寄存器。
// ============================================================================
module mul (
    input  wire        clk,
    input  wire        reset,

    input  wire        in_valid,
    output wire        in_ready,
    input  wire [31:0] a_in,
    input  wire [31:0] b_in,
    input  wire        is_signed,

    output wire        out_valid,
    input  wire        out_ready,
    output wire [31:0] c_low,
    output wire [31:0] c_high
);

reg stage_p_valid;

reg signed [65:0] product_p_r;
wire signed [32:0] operand_a = is_signed ? {a_in[31], a_in}
                                         : {1'b0, a_in};
wire signed [32:0] operand_b = is_signed ? {b_in[31], b_in}
                                         : {1'b0, b_in};

// 输出被消费或当前为空时，P 级可以原子接收下一条乘法。
wire stage_p_advance = ~stage_p_valid | out_ready;

assign in_ready  = stage_p_advance;
assign out_valid = stage_p_valid;
assign c_low     = product_p_r[31:0];
assign c_high    = product_p_r[63:32];

always @(posedge clk) begin
    if (reset)
        stage_p_valid <= 1'b0;
    else if (stage_p_advance)
        stage_p_valid <= in_valid;
end

// 数据通路刻意使用同步、无复位寄存器，以匹配 DSP48E1 的 P 寄存器。
always @(posedge clk) begin
    if (stage_p_advance & in_valid)
        product_p_r <= operand_a * operand_b;
end

endmodule
