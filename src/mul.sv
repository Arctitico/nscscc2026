// ============================================================================
// 32 x 32 三级流水乘法器
//
// 流水级：输入寄存器 -> 乘法寄存器 -> 输出寄存器。无背压时每拍可接收
// 一组新操作数；输出阻塞时冻结整条流水线并保持结果稳定。数据寄存器不带
// 异步复位，便于 Vivado 将它们吸收到 DSP48E1 的 A/B、M、P 寄存器中。
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

reg stage_a_valid;
reg stage_m_valid;
reg stage_p_valid;

reg signed [32:0] operand_a_r;
reg signed [32:0] operand_b_r;
reg signed [65:0] product_m_r;
reg signed [65:0] product_p_r;

// 整体冻结可保证任意背压下每一级的 valid 与载荷保持对应。
wire pipeline_advance = ~stage_p_valid | out_ready;

assign in_ready  = pipeline_advance;
assign out_valid = stage_p_valid;
assign c_low     = product_p_r[31:0];
assign c_high    = product_p_r[63:32];

always @(posedge clk) begin
    if (reset) begin
        stage_a_valid <= 1'b0;
        stage_m_valid <= 1'b0;
        stage_p_valid <= 1'b0;
    end
    else if (pipeline_advance) begin
        stage_a_valid <= in_valid;
        stage_m_valid <= stage_a_valid;
        stage_p_valid <= stage_m_valid;
    end
end

// 数据通路刻意使用同步、无复位寄存器，以匹配 DSP48E1 内部流水寄存器。
always @(posedge clk) begin
    if (pipeline_advance) begin
        if (in_valid) begin
            operand_a_r <= is_signed ? {a_in[31], a_in} : {1'b0, a_in};
            operand_b_r <= is_signed ? {b_in[31], b_in} : {1'b0, b_in};
        end
        if (stage_a_valid)
            product_m_r <= operand_a_r * operand_b_r;
        if (stage_m_valid)
            product_p_r <= product_m_r;
    end
end

endmodule
