// ============================================================================
// Register File read
// ============================================================================
import cpu_pkg::*;

module RF (
    input  wire             clk,
    input  wire             reset,
    input  wire             flush,

    input  wire             IS_to_RF_valid,
    input  wire             EX_allow_in,
    output wire             RF_allow_in,
    output wire             RF_to_EX_valid,

    input  is_to_rf_bus_t   IS_to_RF_BUS,
    output rf_to_ex_bus_t   RF_to_EX_BUS,

    output preg_t           rf_raddr1,
    output preg_t           rf_raddr2,
    output preg_t           rf_raddr3,
    output preg_t           rf_raddr4,
    input  wire   [31:0]    rf_rdata1,
    input  wire   [31:0]    rf_rdata2,
    input  wire   [31:0]    rf_rdata3,
    input  wire   [31:0]    rf_rdata4,

    input  fwd_bus_t        ex_fwd0,
    input  fwd_bus_t        ex_fwd1,
    input  fwd_bus_t        pending_fwd0,
    input  fwd_bus_t        pending_fwd1,
    input  fwd_bus_t        wb_fwd0,
    input  fwd_bus_t        wb_fwd1,
    input  fwd_bus_t        cm_fwd0,
    input  fwd_bus_t        cm_fwd1
);

reg            rf_valid;
is_to_rf_bus_t rf_bus_r;

rr_to_dp_bus_t renamed;
assign renamed = rf_bus_r.dp_to_is_bus.rr_to_dp_bus;

d_bus_t db0;
d_bus_t db1;
assign db0 = renamed.s0.id.d_bus;
assign db1 = renamed.s1.id.d_bus;

assign rf_raddr1 = renamed.s0.psrc1;
assign rf_raddr2 = renamed.s0.psrc2;
assign rf_raddr3 = renamed.s1.psrc1;
assign rf_raddr4 = renamed.s1.psrc2;

function automatic [31:0] forward(
    input preg_t addr,
    input [31:0] raw,
    input fwd_bus_t e1, input fwd_bus_t e0,
    input fwd_bus_t p1, input fwd_bus_t p0,
    input fwd_bus_t w1, input fwd_bus_t w0,
    input fwd_bus_t c1, input fwd_bus_t c0
);
    if      (e1.valid & e1.rf_we & ~e1.is_ld & (e1.pdst == addr) & (addr != preg_t'(0))) forward = e1.rf_wdata;
    else if (e0.valid & e0.rf_we & ~e0.is_ld & (e0.pdst == addr) & (addr != preg_t'(0))) forward = e0.rf_wdata;
    else if (p1.valid & p1.rf_we & ~p1.is_ld & (p1.pdst == addr) & (addr != preg_t'(0))) forward = p1.rf_wdata;
    else if (p0.valid & p0.rf_we & ~p0.is_ld & (p0.pdst == addr) & (addr != preg_t'(0))) forward = p0.rf_wdata;
    else if (w1.valid & w1.rf_we & ~w1.is_ld & (w1.pdst == addr) & (addr != preg_t'(0))) forward = w1.rf_wdata;
    else if (w0.valid & w0.rf_we & ~w0.is_ld & (w0.pdst == addr) & (addr != preg_t'(0))) forward = w0.rf_wdata;
    else if (c1.valid & c1.rf_we &             (c1.pdst == addr) & (addr != preg_t'(0))) forward = c1.rf_wdata;
    else if (c0.valid & c0.rf_we &             (c0.pdst == addr) & (addr != preg_t'(0))) forward = c0.rf_wdata;
    else                                                                               forward = raw;
endfunction

function automatic [31:0] forward_no_ex(
    input preg_t addr,
    input [31:0] raw,
    input fwd_bus_t p1, input fwd_bus_t p0,
    input fwd_bus_t w1, input fwd_bus_t w0,
    input fwd_bus_t c1, input fwd_bus_t c0
);
    if      (p1.valid & p1.rf_we & ~p1.is_ld & (p1.pdst == addr) & (addr != preg_t'(0))) forward_no_ex = p1.rf_wdata;
    else if (p0.valid & p0.rf_we & ~p0.is_ld & (p0.pdst == addr) & (addr != preg_t'(0))) forward_no_ex = p0.rf_wdata;
    else if (w1.valid & w1.rf_we & ~w1.is_ld & (w1.pdst == addr) & (addr != preg_t'(0))) forward_no_ex = w1.rf_wdata;
    else if (w0.valid & w0.rf_we & ~w0.is_ld & (w0.pdst == addr) & (addr != preg_t'(0))) forward_no_ex = w0.rf_wdata;
    else if (c1.valid & c1.rf_we &             (c1.pdst == addr) & (addr != preg_t'(0))) forward_no_ex = c1.rf_wdata;
    else if (c0.valid & c0.rf_we &             (c0.pdst == addr) & (addr != preg_t'(0))) forward_no_ex = c0.rf_wdata;
    else                                                                               forward_no_ex = raw;
endfunction

wire [31:0] fwd_rj0  = forward(rf_raddr1, rf_rdata1, ex_fwd1, ex_fwd0,
                               pending_fwd1, pending_fwd0,
                               wb_fwd1, wb_fwd0, cm_fwd1, cm_fwd0);
wire [31:0] fwd_rkd0 = forward(rf_raddr2, rf_rdata2, ex_fwd1, ex_fwd0,
                               pending_fwd1, pending_fwd0,
                               wb_fwd1, wb_fwd0, cm_fwd1, cm_fwd0);
wire [31:0] fwd_rj1  = forward(rf_raddr3, rf_rdata3, ex_fwd1, ex_fwd0,
                               pending_fwd1, pending_fwd0,
                               wb_fwd1, wb_fwd0, cm_fwd1, cm_fwd0);
wire [31:0] fwd_rkd1 = forward(rf_raddr4, rf_rdata4, ex_fwd1, ex_fwd0,
                               pending_fwd1, pending_fwd0,
                               wb_fwd1, wb_fwd0, cm_fwd1, cm_fwd0);
wire [31:0] mul_rj0   = forward_no_ex(rf_raddr1, rf_rdata1,
                                     pending_fwd1, pending_fwd0,
                                     wb_fwd1, wb_fwd0, cm_fwd1, cm_fwd0);
wire [31:0] mul_rkd0  = forward_no_ex(rf_raddr2, rf_rdata2,
                                     pending_fwd1, pending_fwd0,
                                     wb_fwd1, wb_fwd0, cm_fwd1, cm_fwd0);
wire [31:0] mul_rj1   = forward_no_ex(rf_raddr3, rf_rdata3,
                                     pending_fwd1, pending_fwd0,
                                     wb_fwd1, wb_fwd0, cm_fwd1, cm_fwd0);
wire [31:0] mul_rkd1  = forward_no_ex(rf_raddr4, rf_rdata4,
                                     pending_fwd1, pending_fwd0,
                                     wb_fwd1, wb_fwd0, cm_fwd1, cm_fwd0);

function automatic exload_hit(input fwd_bus_t ld, input need, input preg_t addr);
    exload_hit = ld.valid & ld.rf_we & ld.is_ld & (ld.pdst != preg_t'(0)) &
                 need & (ld.pdst == addr);
endfunction

// 乘法器输入寄存器原本由“EX ALU -> RF 六路旁路 -> DSP 输入”在同一拍
// 直达，这是 100 MHz 下当前最差的真实数据路径。仅对紧邻的
// ALU-to-MUL RAW 依赖互锁一拍，改从 WB 旁路取数；普通 ALU 依赖仍保持
// 零气泡。load/branch-paired-slot1 已由 is_ld 语义覆盖，无需重复判断。
function automatic exwrite_hit(input fwd_bus_t producer,
                               input need, input preg_t addr);
    exwrite_hit = producer.valid & producer.rf_we & ~producer.is_ld &
                  (producer.pdst != preg_t'(0)) & need &
                  (producer.pdst == addr);
endfunction

wire lu0 = exload_hit(ex_fwd0, db0.need_rj,  rf_raddr1) |
           exload_hit(ex_fwd1, db0.need_rj,  rf_raddr1) |
           exload_hit(wb_fwd0, db0.need_rj,  rf_raddr1) |
           exload_hit(wb_fwd1, db0.need_rj,  rf_raddr1) |
           exload_hit(ex_fwd0, db0.need_rkd, rf_raddr2) |
           exload_hit(ex_fwd1, db0.need_rkd, rf_raddr2) |
           exload_hit(wb_fwd0, db0.need_rkd, rf_raddr2) |
           exload_hit(wb_fwd1, db0.need_rkd, rf_raddr2);
wire lu1 = exload_hit(ex_fwd0, db1.need_rj,  rf_raddr3) |
           exload_hit(ex_fwd1, db1.need_rj,  rf_raddr3) |
           exload_hit(wb_fwd0, db1.need_rj,  rf_raddr3) |
           exload_hit(wb_fwd1, db1.need_rj,  rf_raddr3) |
           exload_hit(ex_fwd0, db1.need_rkd, rf_raddr4) |
           exload_hit(ex_fwd1, db1.need_rkd, rf_raddr4) |
           exload_hit(wb_fwd0, db1.need_rkd, rf_raddr4) |
           exload_hit(wb_fwd1, db1.need_rkd, rf_raddr4);

wire load_use   = lu0 | (renamed.v1 & lu1);
wire mul_dep0 = db0.is_mul &
                (exwrite_hit(ex_fwd0, db0.need_rj,  rf_raddr1) |
                 exwrite_hit(ex_fwd1, db0.need_rj,  rf_raddr1) |
                 exwrite_hit(ex_fwd0, db0.need_rkd, rf_raddr2) |
                 exwrite_hit(ex_fwd1, db0.need_rkd, rf_raddr2));
wire mul_dep1 = renamed.v1 & db1.is_mul &
                (exwrite_hit(ex_fwd0, db1.need_rj,  rf_raddr3) |
                 exwrite_hit(ex_fwd1, db1.need_rj,  rf_raddr3) |
                 exwrite_hit(ex_fwd0, db1.need_rkd, rf_raddr4) |
                 exwrite_hit(ex_fwd1, db1.need_rkd, rf_raddr4));
wire mul_ex_dep = mul_dep0 | mul_dep1;
wire rf_ready_go = ~(load_use | mul_ex_dep);
assign RF_allow_in    = ~rf_valid | (rf_ready_go & EX_allow_in);
assign RF_to_EX_valid = rf_valid & rf_ready_go & ~flush;

always @(posedge clk) begin
    if (reset)            rf_valid <= 1'b0;
    else if (flush)       rf_valid <= 1'b0;
    else if (RF_allow_in) rf_valid <= IS_to_RF_valid;
end

always @(posedge clk) begin
    if (IS_to_RF_valid & RF_allow_in) rf_bus_r <= IS_to_RF_BUS;
end

assign RF_to_EX_BUS = '{
    s0: '{
        pc: renamed.s0.id.pc, inst: renamed.s0.id.inst, imm: db0.imm, alu_op: db0.alu_op,
        alu_src1: db0.src1_is_pc ? renamed.s0.id.pc : fwd_rj0,
        alu_src2: db0.src2_is_imm ? db0.imm : fwd_rkd0,
        mul_src1: mul_rj0, mul_src2: mul_rkd0,
        rkd_value: fwd_rkd0,
        is_mul: db0.is_mul, is_cpucfg: db0.is_cpucfg,
        is_branch: db0.is_branch, inst_jirl: db0.inst_jirl,
        inst_beq: db0.inst_beq, inst_bne: db0.inst_bne,
        bp_taken: renamed.s0.id.bp_taken, bp_target: renamed.s0.id.bp_target,
        is_ld: db0.is_ld, is_st: db0.is_st, is_st_b: db0.is_st_b,
        ld_width: db0.ld_width, ld_ext_signed: db0.ld_ext_signed,
        rf_wdata_sel: db0.rf_wdata_sel, rf_we: db0.rf_we, rf_waddr: db0.rf_waddr,
        pdst: renamed.s0.pdst, old_pdst: renamed.s0.old_pdst,
        rob_idx: renamed.s0.rob_idx
    },
    s1: '{
        pc: renamed.s1.id.pc, inst: renamed.s1.id.inst, imm: db1.imm, alu_op: db1.alu_op,
        alu_src1: db1.src1_is_pc ? renamed.s1.id.pc : fwd_rj1,
        alu_src2: db1.src2_is_imm ? db1.imm : fwd_rkd1,
        mul_src1: mul_rj1, mul_src2: mul_rkd1,
        rkd_value: fwd_rkd1,
        is_mul: db1.is_mul, is_cpucfg: db1.is_cpucfg,
        is_branch: db1.is_branch, inst_jirl: db1.inst_jirl,
        inst_beq: db1.inst_beq, inst_bne: db1.inst_bne,
        bp_taken: renamed.s1.id.bp_taken, bp_target: renamed.s1.id.bp_target,
        is_ld: db1.is_ld, is_st: db1.is_st, is_st_b: db1.is_st_b,
        ld_width: db1.ld_width, ld_ext_signed: db1.ld_ext_signed,
        rf_wdata_sel: db1.rf_wdata_sel, rf_we: db1.rf_we, rf_waddr: db1.rf_waddr,
        pdst: renamed.s1.pdst, old_pdst: renamed.s1.old_pdst,
        rob_idx: renamed.s1.rob_idx
    },
    v1: renamed.v1
};

endmodule
