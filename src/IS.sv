// ============================================================================
// IS —— 顺序双发射的 co-issue 决策点。
//
// 五类指令：N=普通，MU=乘法，B=分支，ME=访存，S=特殊/强制单发。
// 在只有一个乘法器、一个 LSU 的前提下，禁止 MU+MU、ME+ME、B+B；
// slot0 B + slot1 ME 也禁止，避免年轻访存先于分支解析产生副作用。
// 其余组合按 tmp.md 支持，包含 slot1 分支以及 MU+ME。若不能配对，先发
// slot0，再把 slot1 重贴为单槽发射。暂不与下一 bundle 做 compaction。
// ============================================================================
import cpu_pkg::*;

module IS (
    input  wire             clk,
    input  wire             reset,
    input  wire             flush,

    input  wire             DP_to_IS_valid,
    input  wire             RF_allow_in,
    output wire             IS_allow_in,
    output wire             IS_to_RF_valid,

    input  dp_to_is_bus_t   DP_to_IS_BUS,
    output is_to_rf_bus_t   IS_to_RF_BUS,

    output wire             perf_coissue,
    output wire             perf_split_total,
    output wire             perf_split_raw,
    output wire             perf_split_mem,
    output wire             perf_split_mul,
    output wire             perf_split_branch
);

reg            is_valid;
dp_to_is_bus_t is_bus_r;
reg            slot1_pending;

id_to_dp_bus_t idp;
assign idp = is_bus_r.id_to_dp_bus;

d_bus_t db0;
d_bus_t db1;
assign db0 = idp.s0.d_bus;
assign db1 = idp.s1.d_bus;

wire        s0_writes = db0.rf_we & (db0.rf_waddr != 5'b0);
wire [ 4:0] s1_rkd    = db1.src_reg_is_rd ? db1.rd : db1.rk;
wire        intra_raw = s0_writes &
                        ((db1.need_rj  & (db0.rf_waddr == db1.rj)) |
                         (db1.need_rkd & (db0.rf_waddr == s1_rkd)));
wire s0_mu = db0.is_mul;
wire s1_mu = db1.is_mul;
wire s0_b  = db0.is_branch;
wire s1_b  = db1.is_branch;
wire s0_me = db0.is_ld | db0.is_st;
wire s1_me = db1.is_ld | db1.is_st;
wire s0_s  = db0.is_cpucfg;
wire s1_s  = db1.is_cpucfg;

wire both_mul       = s0_mu & s1_mu;
wire both_branch    = s0_b  & s1_b;
wire both_mem       = s0_me & s1_me;
wire branch_mem_bad = s0_b  & s1_me;
wire any_special    = s0_s  | s1_s;

wire type_pair_ok = ~any_special &
                    ~both_mul &
                    ~both_branch &
                    ~both_mem &
                    ~branch_mem_bad;

wire can_coissue = idp.v1 & type_pair_ok & ~intra_raw;
wire issuing_split = is_valid & ~slot1_pending & idp.v1 & ~can_coissue;
wire group_last    = slot1_pending | ~issuing_split;

assign IS_to_RF_valid = is_valid;
assign IS_allow_in    = ~is_valid | (group_last & RF_allow_in);
wire   is_fire        = IS_to_RF_valid & RF_allow_in;

// 这些脉冲只描述一次真正完成的 IS 发射。多个 split 原因可以同时为 1，
// 便于区分“本次为何不能配对”；perf_split_total 则始终每个拆分 bundle 只计 1。
assign perf_coissue     = is_fire & ~slot1_pending & idp.v1 & can_coissue;
assign perf_split_total = is_fire & issuing_split;
assign perf_split_raw   = is_fire & issuing_split & intra_raw;
assign perf_split_mem   = is_fire & issuing_split & (both_mem | branch_mem_bad);
assign perf_split_mul   = is_fire & issuing_split & both_mul;
assign perf_split_branch = is_fire & issuing_split & (both_branch | branch_mem_bad);

always @(posedge clk) begin
    if (reset)            is_valid <= 1'b0;
    else if (flush)       is_valid <= 1'b0;
    else if (IS_allow_in) is_valid <= DP_to_IS_valid;
end

always @(posedge clk) begin
    if (DP_to_IS_valid & IS_allow_in) is_bus_r <= DP_to_IS_BUS;
end

always @(posedge clk) begin
    if (reset | flush)                  slot1_pending <= 1'b0;
    else if (is_fire & issuing_split)   slot1_pending <= 1'b1;
    else if (is_fire & slot1_pending)   slot1_pending <= 1'b0;
end

id_to_dp_bus_t out_idp;
always_comb begin
    if (slot1_pending) begin
        out_idp.s0 = idp.s1;
        out_idp.s1 = idp.s1;
        out_idp.v1 = 1'b0;
    end else if (issuing_split) begin
        out_idp.s0 = idp.s0;
        out_idp.s1 = idp.s1;
        out_idp.v1 = 1'b0;
    end else begin
        out_idp = idp;
    end
end

assign IS_to_RF_BUS = '{dp_to_is_bus: '{id_to_dp_bus: out_idp}};

endmodule
