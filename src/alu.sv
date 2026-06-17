// ============================================================================
// alu.sv —— 算术逻辑单元（纯组合）
// 按 12 位 one-hot alu_op 选择运算，编码须与 decoder.sv / cpu_pkg.sv 一致：
//   [0]add [1]sub [2]slt [3]sltu [4]and [5]nor [6]or [7]xor [8]sll [9]srl [10]sra [11]lui
// C3 baseline 只用到 add/sub/and/or/xor/sll/srl/lui，其余运算保留以备扩展。
// ============================================================================
module alu (
    input  wire [31:0] alu_src1,
    input  wire [31:0] alu_src2,
    input  wire [11:0] alu_op,
    output reg  [31:0] alu_result
);

wire [31:0] add_result  = alu_src1 + alu_src2;
wire [31:0] sub_result  = alu_src1 - alu_src2;
wire [31:0] slt_result  = {31'b0, ($signed(alu_src1) < $signed(alu_src2))};
wire [31:0] sltu_result = {31'b0, (alu_src1 < alu_src2)};
wire [31:0] and_result  = alu_src1 & alu_src2;
wire [31:0] nor_result  = ~(alu_src1 | alu_src2);
wire [31:0] or_result   = alu_src1 | alu_src2;
wire [31:0] xor_result  = alu_src1 ^ alu_src2;
wire [31:0] sll_result  = alu_src1 << alu_src2[4:0];
wire [31:0] srl_result  = alu_src1 >> alu_src2[4:0];
wire [31:0] sra_result  = $signed(alu_src1) >>> alu_src2[4:0];
wire [31:0] lui_result  = alu_src2;   // lu12i.w：{i20,12'b0} 已在 imm 中

always @* begin
    unique case (1'b1)
        alu_op[ 0]: alu_result = add_result;
        alu_op[ 1]: alu_result = sub_result;
        alu_op[ 2]: alu_result = slt_result;
        alu_op[ 3]: alu_result = sltu_result;
        alu_op[ 4]: alu_result = and_result;
        alu_op[ 5]: alu_result = nor_result;
        alu_op[ 6]: alu_result = or_result;
        alu_op[ 7]: alu_result = xor_result;
        alu_op[ 8]: alu_result = sll_result;
        alu_op[ 9]: alu_result = srl_result;
        alu_op[10]: alu_result = sra_result;
        alu_op[11]: alu_result = lui_result;
        default:    alu_result = 32'b0;
    endcase
end

endmodule
