// ============================================================================
// Register File read
//
// 正常情况下，操作数没准备好就停在 RF；
//
// 唯一例外是，当 Store 地址已准备好、只差紧邻 load 产生的 store data 时，
// 允许 Store 提前进入 EX1.
// ============================================================================
import cpu_pkg::*;

module RF (
    input  wire             clk,
    input  wire             reset,
    input  wire             flush,

    input  wire             IS_to_RF_valid,
    input  wire             EX1_allow_in,
    output wire             RF_allow_in,
    output wire             RF_to_EX_valid,

    input  is_to_rf_bus_t   IS_to_RF_BUS,
    output rf_to_ex_bus_t   RF_to_EX_BUS,

    output wire   [ 4:0]    rf_raddr1,
    output wire   [ 4:0]    rf_raddr2,
    output wire   [ 4:0]    rf_raddr3,
    output wire   [ 4:0]    rf_raddr4,
    input  wire   [31:0]    rf_rdata1,
    input  wire   [31:0]    rf_rdata2,
    input  wire   [31:0]    rf_rdata3,
    input  wire   [31:0]    rf_rdata4,

    input  fwd_bus_t        ex1_fwd0,
    input  fwd_bus_t        ex1_fwd1,
    input  wire             ex1_is_load0,
    input  wire             ex1_is_load1,
    input  fwd_bus_t        ex2_fwd0,
    input  fwd_bus_t        ex2_fwd1,
    input  fwd_bus_t        cm_fwd0,
    input  fwd_bus_t        cm_fwd1
);

reg            rf_valid;
is_to_rf_bus_t rf_bus_r;

id_to_dp_bus_t idp;
assign idp = rf_bus_r.dp_to_is_bus.id_to_dp_bus;

d_bus_t db0;
d_bus_t db1;
assign db0 = idp.s0.d_bus;
assign db1 = idp.s1.d_bus;

// IS 只会让 SLL -> ADD/XOR 的 intra-RAW 共发。进入 RF 后重新按保存的
// 完整 decoded bundle 生成精确源标记，避免增加 IS->RF payload。
wire       bundle_s0_writes = idp.v1 & db0.rf_we &
                              (db0.rf_waddr != 5'b0);
wire [4:0] bundle_s1_rkd = db1.src_reg_is_rd ? db1.rd : db1.rk;
wire       s1_dep_rj_from_s0 = bundle_s0_writes & db1.need_rj &
                               (db0.rf_waddr == db1.rj);
wire       s1_dep_rkd_from_s0 = bundle_s0_writes & db1.need_rkd &
                                (db0.rf_waddr == bundle_s1_rkd);

assign rf_raddr1 = db0.rj;
assign rf_raddr2 = db0.src_reg_is_rd ? db0.rd : db0.rk;
assign rf_raddr3 = db1.rj;
assign rf_raddr4 = db1.src_reg_is_rd ? db1.rd : db1.rk;

// 一次选出实际依赖的最年轻生产者，同时返回其数据和 pending 状态。
// 返回值 [32] 为 pending，[31:0] 为数据。尚未 ready 时数据不会被普通
// consumer 锁存；load->store-data 的唯一例外由 EX1 专用完成口接管。
function automatic [32:0] resolve_operand(
    input [ 4:0] addr,
    input [31:0] raw,
    input fwd_bus_t ex1_s1, input fwd_bus_t ex1_s0,
    input fwd_bus_t ex2_s1, input fwd_bus_t ex2_s0,
    input fwd_bus_t cm_s1, input fwd_bus_t cm_s0
);
    if (addr == 5'b0)
        resolve_operand = {1'b0, raw};
    else if (ex1_s1.valid & ex1_s1.rf_we & (ex1_s1.rf_waddr == addr))
        resolve_operand = {~ex1_s1.result_ready, ex1_s1.rf_wdata};
    else if (ex1_s0.valid & ex1_s0.rf_we & (ex1_s0.rf_waddr == addr))
        resolve_operand = {~ex1_s0.result_ready, ex1_s0.rf_wdata};
    else if (ex2_s1.valid & ex2_s1.rf_we & (ex2_s1.rf_waddr == addr))
        resolve_operand = {~ex2_s1.result_ready, ex2_s1.rf_wdata};
    else if (ex2_s0.valid & ex2_s0.rf_we & (ex2_s0.rf_waddr == addr))
        resolve_operand = {~ex2_s0.result_ready, ex2_s0.rf_wdata};
    else if (cm_s1.valid & cm_s1.rf_we & (cm_s1.rf_waddr == addr))
        resolve_operand = {~cm_s1.result_ready, cm_s1.rf_wdata};
    else if (cm_s0.valid & cm_s0.rf_we & (cm_s0.rf_waddr == addr))
        resolve_operand = {~cm_s0.result_ready, cm_s0.rf_wdata};
    else
        resolve_operand = {1'b0, raw};
endfunction

wire [32:0] resolved_rj0 = resolve_operand(
    rf_raddr1, rf_rdata1, ex1_fwd1, ex1_fwd0, ex2_fwd1, ex2_fwd0,
    cm_fwd1, cm_fwd0);
wire [32:0] resolved_rkd0 = resolve_operand(
    rf_raddr2, rf_rdata2, ex1_fwd1, ex1_fwd0, ex2_fwd1, ex2_fwd0,
    cm_fwd1, cm_fwd0);
wire [32:0] resolved_rj1 = resolve_operand(
    rf_raddr3, rf_rdata3, ex1_fwd1, ex1_fwd0, ex2_fwd1, ex2_fwd0,
    cm_fwd1, cm_fwd0);
wire [32:0] resolved_rkd1 = resolve_operand(
    rf_raddr4, rf_rdata4, ex1_fwd1, ex1_fwd0, ex2_fwd1, ex2_fwd0,
    cm_fwd1, cm_fwd0);

wire [31:0] fwd_rj0  = resolved_rj0[31:0];
wire [31:0] fwd_rkd0 = resolved_rkd0[31:0];
wire [31:0] fwd_rj1  = resolved_rj1[31:0];
wire [31:0] fwd_rkd1 = resolved_rkd1[31:0];

// 前递与 pending 共享同一次年龄选择。年轻同名写者已经覆盖老写者时，
// consumer 只依赖年轻写者；不能把老 load/MUL 的未完成状态再 OR 进来。
wire rj_pending0 = db0.need_rj  & resolved_rj0[32];
wire rk_pending0 = db0.need_rkd & resolved_rkd0[32];
// 同 bundle 的 slot0 是 slot1 对应源的最年轻生产者。该源不能再被
// regfile/EX1/EX2/CM 中更老的同名写者标成 pending；slot0 自身若依赖
// 老生产者，仍由 slot0 的普通 pending 阻塞整个 bundle。
wire rj_pending1 = db1.need_rj  & resolved_rj1[32] &
                   ~s1_dep_rj_from_s0;
wire rk_pending1 = db1.need_rkd & resolved_rkd1[32] &
                   ~s1_dep_rkd_from_s0;

// 晚旁路只覆盖当前 EX1 中最年轻的同名生产者确为 load 的情况。若 slot1
// 已有更年轻的同名 ALU 写者，不能误取 slot0 load。
function automatic youngest_ex1_load(
    input need,
    input [4:0] addr,
    input fwd_bus_t slot1, input fwd_bus_t slot0,
    input slot1_is_load, input slot0_is_load
);
    if (~need | (addr == 5'b0))
        youngest_ex1_load = 1'b0;
    else if (slot1.valid & slot1.rf_we & (slot1.rf_waddr == addr))
        youngest_ex1_load = slot1_is_load;
    else if (slot0.valid & slot0.rf_we & (slot0.rf_waddr == addr))
        youngest_ex1_load = slot0_is_load;
    else
        youngest_ex1_load = 1'b0;
endfunction

wire rk_ex1_load0 = youngest_ex1_load(db0.need_rkd, rf_raddr2,
                                      ex1_fwd1, ex1_fwd0,
                                      ex1_is_load1, ex1_is_load0);
wire rk_ex1_load1 = youngest_ex1_load(db1.need_rkd, rf_raddr4,
                                      ex1_fwd1, ex1_fwd0,
                                      ex1_is_load1, ex1_is_load0);

// 允许 store 提前进入 EX1 的条件：当前指令必须是 store，store 地址必须已经准备好，
// store 数据确实还没准备好，数据的最年轻生产者是 EX1 中的真正 load.
wire late_store_ok0 = db0.is_st & ~rj_pending0 & rk_pending0 & rk_ex1_load0;
wire late_store_ok1 = db1.is_st & ~rj_pending1 & rk_pending1 & rk_ex1_load1;

wire any_pending0 = rj_pending0 | rk_pending0;
wire any_pending1 = rj_pending1 | rk_pending1;

// 该槽存在尚未完成、又不能用专用晚旁路解决的 RAW 时，必须阻塞 RF。
wire dependency_stall0 = any_pending0 & ~late_store_ok0;
wire dependency_stall1 = any_pending1 & ~late_store_ok1;

// 当前 RF bundle 中至少有一个有效槽必须等待生产者结果。
wire rf_dependency_stall = dependency_stall0 | (idp.v1 & dependency_stall1);

// EX1 的 mul_src1/mul_src2 就是乘法器 A/B 输入级。普通前递先在本级
// 选定并锁存，下一拍再进入 DSP 乘积级，因此无需额外 ALU-to-MUL 气泡。
wire rf_ready_go = ~rf_dependency_stall;
assign RF_allow_in    = ~rf_valid | (rf_ready_go & EX1_allow_in);
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
        pc: idp.s0.pc, inst: idp.s0.inst, imm: db0.imm, alu_op: db0.alu_op,
        alu_src1: db0.src1_is_pc ? idp.s0.pc : fwd_rj0,
        alu_src2: db0.src2_is_imm ? db0.imm : fwd_rkd0,
        mul_src1: fwd_rj0, mul_src2: fwd_rkd0,
        rkd_value: fwd_rkd0,
        late_store_data: late_store_ok0,
        rkd_addr: rf_raddr2,
        is_mul: db0.is_mul, is_cpucfg: db0.is_cpucfg,
        is_branch: db0.is_branch, inst_jirl: db0.inst_jirl,
        inst_beq: db0.inst_beq, inst_bne: db0.inst_bne,
        bp_taken: idp.s0.bp_taken, bp_target: idp.s0.bp_target,
        is_ld: db0.is_ld, is_st: db0.is_st, is_st_b: db0.is_st_b,
        ld_width: db0.ld_width, ld_ext_signed: db0.ld_ext_signed,
        rf_wdata_sel: db0.rf_wdata_sel, rf_we: db0.rf_we, rf_waddr: db0.rf_waddr
    },
    s1: '{
        pc: idp.s1.pc, inst: idp.s1.inst, imm: db1.imm, alu_op: db1.alu_op,
        alu_src1: db1.src1_is_pc ? idp.s1.pc : fwd_rj1,
        alu_src2: db1.src2_is_imm ? db1.imm : fwd_rkd1,
        mul_src1: fwd_rj1, mul_src2: fwd_rkd1,
        rkd_value: fwd_rkd1,
        late_store_data: late_store_ok1,
        rkd_addr: rf_raddr4,
        is_mul: db1.is_mul, is_cpucfg: db1.is_cpucfg,
        is_branch: db1.is_branch, inst_jirl: db1.inst_jirl,
        inst_beq: db1.inst_beq, inst_bne: db1.inst_bne,
        bp_taken: idp.s1.bp_taken, bp_target: idp.s1.bp_target,
        is_ld: db1.is_ld, is_st: db1.is_st, is_st_b: db1.is_st_b,
        ld_width: db1.ld_width, ld_ext_signed: db1.ld_ext_signed,
        rf_wdata_sel: db1.rf_wdata_sel, rf_we: db1.rf_we, rf_waddr: db1.rf_waddr
    },
    s1_dep_rj_from_s0: s1_dep_rj_from_s0,
    s1_dep_rkd_from_s0: s1_dep_rkd_from_s0,
    v1: idp.v1
};

endmodule
