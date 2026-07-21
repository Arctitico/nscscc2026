// ============================================================================
// 32 x 32 multiplier
// ============================================================================
module mul (
    input  wire [31:0] a_in,
    input  wire [31:0] b_in,
    input  wire        is_signed,
    output wire [31:0] c_low,
    output wire [31:0] c_high
);

wire signed [32:0] operand_a = is_signed ? {a_in[31], a_in} : {1'b0, a_in};
wire signed [32:0] operand_b = is_signed ? {b_in[31], b_in} : {1'b0, b_in};
wire signed [65:0] product   = operand_a * operand_b;

assign c_low  = product[31:0];
assign c_high = product[63:32];

endmodule
