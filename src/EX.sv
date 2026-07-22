// ============================================================================
// Execute：双 ALU，单数据口，单三级乘法器。
// IS 保证同一 bundle 最多一条访存、最多一条分支；
// 一个 mul.w 只可与独立纯 ALU 共发，bundle 仍整体等待乘法结果后写回。
// ============================================================================
import cpu_pkg::*;

module EX (
    input  wire             clk,
    input  wire             reset,

    input  wire             RF_to_EX_valid,
    input  wire             WB_allow_in,
    output wire             EX_allow_in,
    output wire             EX_to_WB_valid,

    input  rf_to_ex_bus_t   RF_to_EX_BUS,
    output ex_to_wb_bus_t   EX_to_WB_BUS,

    output wire             redirect,
    output wire   [31:0]    redirect_target,

    output wire             bp_upd_en,
    output wire   [31:0]    bp_upd_pc,
    output wire             bp_upd_taken,
    output wire             bp_upd_is_cond,
    output wire   [31:0]    bp_upd_target,

    output fwd_bus_t        ex_fwd0,
    output fwd_bus_t        ex_fwd1,

    output wire             data_sram_en,
    output wire   [ 3:0]    data_sram_we,
    output wire   [ 2:0]    data_sram_size,
    output wire   [31:0]    data_sram_addr,
    output wire   [31:0]    data_sram_wdata,
    input  wire             data_addr_ok,

    output wire             perf_data_wait,
    output wire             perf_mul_wait,
    output wire             perf_branch_mispred
);

reg            ex_valid;
rf_to_ex_bus_t eb;

rf_ex_slot_t s0;
rf_ex_slot_t s1;
assign s0 = eb.s0;
assign s1 = eb.s1;

wire ex_v0 = ex_valid;
wire ex_v1 = ex_valid & eb.v1;

wire [31:0] alu_result0;
wire [31:0] alu_result1;
alu u_alu0(.alu_src1(s0.alu_src1), .alu_src2(s0.alu_src2),
           .alu_op(s0.alu_op), .alu_result(alu_result0));
alu u_alu1(.alu_src1(s1.alu_src1), .alu_src2(s1.alu_src2),
           .alu_op(s1.alu_op), .alu_result(alu_result1));

// ---------------- 分支解析 ----------------
wire        eq0         = (s0.alu_src1 == s0.rkd_value);
wire        uncond0     = s0.is_branch & ~s0.inst_beq & ~s0.inst_bne;
wire        cond_taken0 = (s0.inst_beq & eq0) | (s0.inst_bne & ~eq0);
wire        br_taken0   = ex_v0 & (uncond0 | cond_taken0);
wire [31:0] br_target0  = s0.inst_jirl ? (s0.alu_src1 + s0.imm)
                                         : (s0.pc + s0.imm);

wire        eq1         = (s1.alu_src1 == s1.rkd_value);
wire        uncond1     = s1.is_branch & ~s1.inst_beq & ~s1.inst_bne;
wire        cond_taken1 = (s1.inst_beq & eq1) | (s1.inst_bne & ~eq1);
wire        br_taken1   = ex_v1 & (uncond1 | cond_taken1);
wire [31:0] br_target1  = s1.inst_jirl ? (s1.alu_src1 + s1.imm)
                                         : (s1.pc + s1.imm);

wire mispred0 = ex_v0 & s0.is_branch &
                ((s0.bp_taken ^ br_taken0) |
                 (br_taken0 & s0.bp_taken & (br_target0 != s0.bp_target)));
wire mispred1 = ex_v1 & s1.is_branch &
                ((s1.bp_taken ^ br_taken1) |
                 (br_taken1 & s1.bp_taken & (br_target1 != s1.bp_target)));

// slot0 分支可与非分支 slot1 共发；误预测时必须抹掉更年轻的 slot1。
wire ex_v1_eff = ex_v1 & ~mispred0;

assign redirect_target = mispred0 ? (br_taken0 ? br_target0 : (s0.pc + 32'd4))
                                   : (br_taken1 ? br_target1 : (s1.pc + 32'd4));

// ---------------- 单数据口 ----------------
wire is_mem0 = ex_v0 & (s0.is_ld | s0.is_st);
// IS 禁止 slot0 分支与 slot1 访存共发，因此 slot1 访存不会成为 slot0
// 误预测产生的错误路径。直接使用寄存后的 ex_v1，避免分支比较直通数据口。
wire is_mem1 = ex_v1 & (s1.is_ld | s1.is_st);
wire mem_sel1 = is_mem1;

wire [31:0] mem_addr = mem_sel1 ? alu_result1 : alu_result0;
wire        st_sel   = mem_sel1 ? s1.is_st : s0.is_st;
wire        stb_sel  = mem_sel1 ? s1.is_st_b : s0.is_st_b;
wire [ 3:0] ldw_sel  = mem_sel1 ? s1.ld_width : s0.ld_width;
wire [31:0] rkd_sel  = mem_sel1 ? s1.rkd_value : s0.rkd_value;

wire [ 3:0] st_wstrb = stb_sel ? (4'b0001 << mem_addr[1:0]) : 4'b1111;
wire [31:0] st_wdata = stb_sel ? {4{rkd_sel[7:0]}} : rkd_sel;

assign data_sram_en    = is_mem0 | is_mem1;
assign data_sram_we    = data_sram_en & st_sel ? st_wstrb : 4'b0;
assign data_sram_size  = (stb_sel | (ldw_sel == 4'b0001)) ? 3'b000 : 3'b010;
assign data_sram_addr  = mem_addr;
assign data_sram_wdata = st_wdata;

// ---------------- 共享乘法器 ----------------
wire incoming_mul1 = RF_to_EX_BUS.v1 & RF_to_EX_BUS.s1.is_mul;
wire incoming_mul  = RF_to_EX_BUS.s0.is_mul | incoming_mul1;
wire ex_mul1       = eb.v1 & s1.is_mul;
wire ex_has_mul    = s0.is_mul | ex_mul1;

wire        mul_in_valid;
wire        mul_in_ready;
wire        mul_out_valid;
wire        mul_out_ready;
wire [31:0] mul_low;
wire [31:0] mul_high_unused;

wire ex_ready_go   = ex_has_mul       ? mul_out_valid
                   : (is_mem0 | is_mem1) ? data_addr_ok
                                         : 1'b1;
wire ex_slot_allow = ~ex_valid | (ex_ready_go & WB_allow_in);
assign EX_allow_in = ex_slot_allow &
                     (~RF_to_EX_valid | ~incoming_mul | mul_in_ready);
assign EX_to_WB_valid = ex_valid & ex_ready_go;

// WB 可能正在等待更老的访存响应。分支在 EX 被背压时只保留
// 解析结果，等本 bundle 真正向 WB 推进时再冲刷，避免每拍重复 redirect。
wire branch_resolve_fire = ex_ready_go & WB_allow_in;
assign redirect = (mispred0 | mispred1) & branch_resolve_fire;

assign perf_data_wait      = ex_valid & (is_mem0 | is_mem1) & ~data_addr_ok;
assign perf_mul_wait       = ex_valid & ex_has_mul & ~mul_out_valid;
assign perf_branch_mispred = redirect & ex_ready_go & WB_allow_in;

assign mul_in_valid  = RF_to_EX_valid & EX_allow_in & incoming_mul;
assign mul_out_ready = ex_valid & ex_has_mul & WB_allow_in;

mul u_mul (
    .clk(clk), .reset(reset),
    .in_valid(mul_in_valid), .in_ready(mul_in_ready),
    .a_in(incoming_mul1 ? RF_to_EX_BUS.s1.alu_src1 : RF_to_EX_BUS.s0.alu_src1),
    .b_in(incoming_mul1 ? RF_to_EX_BUS.s1.alu_src2 : RF_to_EX_BUS.s0.alu_src2),
    .is_signed(1'b1),
    .out_valid(mul_out_valid), .out_ready(mul_out_ready),
    .c_low(mul_low), .c_high(mul_high_unused)
);

always @(posedge clk) begin
    if (reset)            ex_valid <= 1'b0;
    else if (EX_allow_in) ex_valid <= RF_to_EX_valid;
end

always @(posedge clk) begin
    if (RF_to_EX_valid & EX_allow_in) eb <= RF_to_EX_BUS;
end

function automatic [31:0] cpucfg(input [31:0] index);
    // 无 Cache 架构路线：CPUCFG[0x10] 报告 I/D Cache 均不存在。
    case (index)
        32'h0000_0010: cpucfg = 32'h0000_0000;
        default:       cpucfg = 32'h0000_0000;
    endcase
endfunction

wire [31:0] execute_result0 = s0.is_cpucfg ? cpucfg(s0.alu_src1)
                              : s0.is_mul   ? mul_low : alu_result0;
wire [31:0] execute_result1 = s1.is_cpucfg ? cpucfg(s1.alu_src1)
                              : s1.is_mul   ? mul_low : alu_result1;

wire upd_sel1   = ex_v1_eff & s1.is_branch;
wire has_branch = (ex_v0 & s0.is_branch) | upd_sel1;
assign bp_upd_en      = EX_to_WB_valid & WB_allow_in & has_branch;
assign bp_upd_pc      = upd_sel1 ? s1.pc : s0.pc;
assign bp_upd_taken   = upd_sel1 ? br_taken1 : br_taken0;
assign bp_upd_is_cond = upd_sel1 ? (s1.inst_beq | s1.inst_bne)
                                 : (s0.inst_beq | s0.inst_bne);
assign bp_upd_target  = upd_sel1 ? br_target1 : br_target0;

assign EX_to_WB_BUS = '{
    s0: '{pc: s0.pc, inst: s0.inst, alu_result: execute_result0,
          is_mem: is_mem0, addr_lo: alu_result0[1:0],
          ld_width: s0.ld_width, ld_ext_signed: s0.ld_ext_signed,
          rf_wdata_sel: s0.rf_wdata_sel, rf_we: s0.rf_we, rf_waddr: s0.rf_waddr},
    s1: '{pc: s1.pc, inst: s1.inst, alu_result: execute_result1,
          is_mem: is_mem1, addr_lo: alu_result1[1:0],
          ld_width: s1.ld_width, ld_ext_signed: s1.ld_ext_signed,
          rf_wdata_sel: s1.rf_wdata_sel, rf_we: s1.rf_we, rf_waddr: s1.rf_waddr},
    v1: ex_v1_eff
};

wire [31:0] fwd_data0 = (s0.rf_wdata_sel == 2'b10) ? (s0.pc + 32'd4)
                                                       : execute_result0;
wire [31:0] fwd_data1 = (s1.rf_wdata_sel == 2'b10) ? (s1.pc + 32'd4)
                                                       : execute_result1;
assign ex_fwd0 = '{valid: ex_v0 & (~s0.is_mul | mul_out_valid),
                   rf_we: s0.rf_we, is_ld: s0.is_ld,
                   rf_waddr: s0.rf_waddr, rf_wdata: fwd_data0};
assign ex_fwd1 = '{valid: ex_v1_eff & (~s1.is_mul | mul_out_valid),
                   rf_we: s1.rf_we, is_ld: s1.is_ld,
                   rf_waddr: s1.rf_waddr, rf_wdata: fwd_data1};

endmodule
