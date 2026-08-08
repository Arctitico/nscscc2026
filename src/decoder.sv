// ============================================================================
// decoder
// ============================================================================
import cpu_pkg::*;

module decoder(
    input  wire    [31:0] inst,
    output d_bus_t        d_bus
);

wire [63:0] op_31_26_d;
wire [15:0] op_25_22_d;
wire [ 3:0] op_21_20_d;
wire [31:0] op_19_15_d;

wire [ 5:0] op_31_26 = inst[31:26];
wire [ 3:0] op_25_22 = inst[25:22];
wire [ 1:0] op_21_20 = inst[21:20];
wire [ 4:0] op_19_15 = inst[19:15];

decoder_6_64 u_dec0(.in(op_31_26), .out(op_31_26_d));
decoder_4_16 u_dec1(.in(op_25_22), .out(op_25_22_d));
decoder_2_4  u_dec2(.in(op_21_20), .out(op_21_20_d));
decoder_5_32 u_dec3(.in(op_19_15), .out(op_19_15_d));

wire inst_add_w     = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h00];
wire inst_sub_w     = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h02];
wire inst_slt       = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h04];
wire inst_sltu      = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h05];
wire inst_nor       = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h08];
wire inst_and       = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h09];
wire inst_or        = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h0a];
wire inst_xor       = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h0b];
wire inst_sll_w     = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h0e];
wire inst_srl_w     = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h0f];
wire inst_sra_w     = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h10];
wire inst_mul_w     = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h18];
wire inst_mulh_w    = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h19];
wire inst_mulh_wu   = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h1a];

wire inst_slli_w    = op_31_26_d[6'h00] & op_25_22_d[4'h1] & op_21_20_d[2'h0] & op_19_15_d[5'h01];
wire inst_srli_w    = op_31_26_d[6'h00] & op_25_22_d[4'h1] & op_21_20_d[2'h0] & op_19_15_d[5'h09];
wire inst_srai_w    = op_31_26_d[6'h00] & op_25_22_d[4'h1] & op_21_20_d[2'h0] & op_19_15_d[5'h11];

wire inst_addi_w    = op_31_26_d[6'h00] & op_25_22_d[4'ha];
wire inst_andi      = op_31_26_d[6'h00] & op_25_22_d[4'hd];
wire inst_ori       = op_31_26_d[6'h00] & op_25_22_d[4'he];
wire inst_xori      = op_31_26_d[6'h00] & op_25_22_d[4'hf];
wire inst_slti      = op_31_26_d[6'h00] & op_25_22_d[4'h8];
wire inst_sltui     = op_31_26_d[6'h00] & op_25_22_d[4'h9];

wire inst_lu12i_w   = op_31_26_d[6'h05] & ~inst[25];
wire inst_pcaddu12i = op_31_26_d[6'h07] & ~inst[25];

wire inst_ld_w      = op_31_26_d[6'h0a] & op_25_22_d[4'h2];
wire inst_ld_b      = op_31_26_d[6'h0a] & op_25_22_d[4'h0];
wire inst_ld_h      = op_31_26_d[6'h0a] & op_25_22_d[4'h1];
wire inst_ld_bu     = op_31_26_d[6'h0a] & op_25_22_d[4'h8];
wire inst_ld_hu     = op_31_26_d[6'h0a] & op_25_22_d[4'h9];
wire inst_st_w      = op_31_26_d[6'h0a] & op_25_22_d[4'h6];
wire inst_st_b      = op_31_26_d[6'h0a] & op_25_22_d[4'h4];
wire inst_st_h      = op_31_26_d[6'h0a] & op_25_22_d[4'h5];

wire inst_jirl      = op_31_26_d[6'h13];
wire inst_b         = op_31_26_d[6'h14];
wire inst_bl        = op_31_26_d[6'h15];
wire inst_beq       = op_31_26_d[6'h16];
wire inst_bne       = op_31_26_d[6'h17];
wire inst_blt       = op_31_26_d[6'h18];
wire inst_bge       = op_31_26_d[6'h19];
wire inst_bltu      = op_31_26_d[6'h1a];
wire inst_bgeu      = op_31_26_d[6'h1b];

// cpucfg rd, rj：固定字段 rk=0x1b，其余 opcode 字段全 0
wire inst_cpucfg    = op_31_26_d[6'h00] & op_25_22_d[4'h0] &
                      op_21_20_d[2'h0] & op_19_15_d[5'h00] & (inst[14:10] == 5'h1b);

assign d_bus.rd = inst[4:0];
assign d_bus.rj = inst[9:5];
assign d_bus.rk = inst[14:10];

assign d_bus.alu_op = {
    inst_lu12i_w,                                                  // [11] lui
    inst_sra_w | inst_srai_w,                                      // [10] sra
    inst_srl_w | inst_srli_w,                                      // [ 9] srl
    inst_slli_w | inst_sll_w,                                      // [ 8] sll
    inst_xor | inst_xori,                                          // [ 7] xor
    inst_or  | inst_ori,                                           // [ 6] or
    inst_nor,                                                      // [ 5] nor
    inst_and | inst_andi,                                          // [ 4] and
    inst_sltu | inst_sltui,                                        // [ 3] sltu
    inst_slt | inst_slti,                                          // [ 2] slt
    inst_sub_w,                                                    // [ 1] sub
    inst_add_w | inst_addi_w | inst_pcaddu12i                      // [ 0] add
};

assign d_bus.src1_is_pc    = inst_bl | inst_pcaddu12i;
assign d_bus.src2_is_imm   = inst_addi_w | inst_andi | inst_ori | inst_xori |
                             inst_slti | inst_sltui |
                             inst_slli_w | inst_srli_w | inst_srai_w |
                             inst_lu12i_w | inst_pcaddu12i |
                             inst_ld_w | inst_ld_b | inst_ld_h | inst_ld_bu | inst_ld_hu |
                             inst_st_w | inst_st_b | inst_st_h;
assign d_bus.src_reg_is_rd = inst_beq | inst_bne | inst_blt | inst_bge | inst_bltu | inst_bgeu |
                             inst_st_w | inst_st_b | inst_st_h;

assign d_bus.rf_we    = inst_add_w | inst_sub_w | inst_slt | inst_sltu | inst_nor |
                        inst_and | inst_or | inst_xor | inst_sll_w | inst_srl_w | inst_sra_w |
                        inst_mul_w | inst_mulh_w | inst_mulh_wu |
                        inst_slli_w | inst_srli_w | inst_srai_w |
                        inst_addi_w | inst_andi | inst_ori | inst_xori | inst_slti | inst_sltui |
                        inst_lu12i_w | inst_pcaddu12i |
                        inst_ld_w | inst_ld_b | inst_ld_h | inst_ld_bu | inst_ld_hu |
                        inst_bl | inst_jirl | inst_cpucfg;
assign d_bus.rf_waddr = inst_bl ? 5'd1 : inst[4:0];

assign d_bus.rf_wdata_sel = (inst_ld_w | inst_ld_b | inst_ld_h | inst_ld_bu | inst_ld_hu) ? 2'b01 :
                            (inst_bl | inst_jirl) ? 2'b10 : 2'b00;

assign d_bus.need_rj  = inst_add_w | inst_sub_w | inst_slt | inst_sltu | inst_nor |
                        inst_and | inst_or | inst_xor | inst_sll_w | inst_srl_w | inst_sra_w |
                        inst_mul_w | inst_mulh_w | inst_mulh_wu | inst_cpucfg |
                        inst_slli_w | inst_srli_w | inst_srai_w |
                        inst_addi_w | inst_andi | inst_ori | inst_xori | inst_slti | inst_sltui |
                        inst_ld_w | inst_ld_b | inst_ld_h | inst_ld_bu | inst_ld_hu |
                        inst_st_w | inst_st_b | inst_st_h |
                        inst_jirl | inst_beq | inst_bne | inst_blt | inst_bge | inst_bltu | inst_bgeu;
assign d_bus.need_rkd = inst_add_w | inst_sub_w | inst_slt | inst_sltu | inst_nor |
                        inst_and | inst_or | inst_xor | inst_sll_w | inst_srl_w | inst_sra_w |
                        inst_mul_w | inst_mulh_w | inst_mulh_wu |                  // rk
                        inst_st_w | inst_st_b | inst_st_h |
                        inst_beq | inst_bne | inst_blt | inst_bge | inst_bltu | inst_bgeu; // rd

assign d_bus.is_mul    = inst_mul_w | inst_mulh_w | inst_mulh_wu;
assign d_bus.mul_signed = inst_mul_w | inst_mulh_w;
assign d_bus.mul_high   = inst_mulh_w | inst_mulh_wu;
assign d_bus.is_cpucfg = inst_cpucfg;

assign d_bus.is_ld = inst_ld_w | inst_ld_b | inst_ld_h | inst_ld_bu | inst_ld_hu;
assign d_bus.is_st = inst_st_w | inst_st_b | inst_st_h;
assign d_bus.ld_width = (inst_ld_w | inst_st_w) ? 4'b1111 :
                        (inst_ld_h | inst_ld_hu | inst_st_h) ? 4'b0011 :
                        (inst_ld_b | inst_ld_bu | inst_st_b) ? 4'b0001 : 4'b0000;
assign d_bus.ld_ext_signed = inst_ld_b | inst_ld_h;

assign d_bus.is_branch = inst_b | inst_bl | inst_jirl | inst_beq | inst_bne |
                         inst_blt | inst_bge | inst_bltu | inst_bgeu;
assign d_bus.inst_jirl = inst_jirl;
assign d_bus.br_cond = inst_beq  ? BR_EQ  :
                       inst_bne  ? BR_NE  :
                       inst_blt  ? BR_LT  :
                       inst_bge  ? BR_GE  :
                       inst_bltu ? BR_LTU :
                       inst_bgeu ? BR_GEU : BR_UNCOND;

wire [11:0] i12 = inst[21:10];
wire [19:0] i20 = inst[24:5];
wire [15:0] i16 = inst[25:10];
wire [25:0] i26 = {inst[9:0], inst[25:10]};
wire [ 4:0] ui5 = inst[14:10];

logic [31:0] imm_val;
always_comb begin
    unique case (1'b1)
        (inst_slli_w | inst_srli_w | inst_srai_w)            : imm_val = {27'b0, ui5};
        (inst_addi_w | inst_slti | inst_sltui |
         inst_ld_w | inst_ld_b | inst_ld_h | inst_ld_bu | inst_ld_hu |
         inst_st_w | inst_st_b | inst_st_h)                  : imm_val = {{20{i12[11]}}, i12};
        (inst_andi | inst_ori | inst_xori)                   : imm_val = {20'b0, i12};
        (inst_lu12i_w | inst_pcaddu12i)                      : imm_val = {i20, 12'b0};
        (inst_b | inst_bl)                                   : imm_val = {{4{i26[25]}}, i26, 2'b0};
        (inst_beq | inst_bne | inst_blt | inst_bge |
         inst_bltu | inst_bgeu | inst_jirl)                  : imm_val = {{14{i16[15]}}, i16, 2'b0};
        default                                              : imm_val = 32'b0;
    endcase
end
assign d_bus.imm = imm_val;

endmodule
