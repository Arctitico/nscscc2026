// ============================================================================
// IS —— 顺序双发射的 co-issue 决策点。
//
// 两槽同拍发射需要同时满足：最多一条访存、分支只能位于 slot0 且 slot1
// 不是访存、slot1 不读 slot0 的目的寄存器；若含一个 mul.w，另一槽必须是
// 独立纯 ALU。不满足时先发 slot0，再把 slot1 重贴为单槽发射。这样 EX 只
// 保留一套分支解析，并避免 mispredict 组合结果进入 forwarding/allow-in。
// 暂不与下一 bundle 做 compaction。
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

rr_to_dp_bus_t renamed;
assign renamed = is_bus_r.rr_to_dp_bus;

d_bus_t db0;
d_bus_t db1;
assign db0 = renamed.s0.id.d_bus;
assign db1 = renamed.s1.id.d_bus;

wire        s0_writes = db0.rf_we & (renamed.s0.pdst != preg_t'(0));
wire        intra_raw = s0_writes &
                        ((db1.need_rj  & (renamed.s0.pdst == renamed.s1.psrc1)) |
                         (db1.need_rkd & (renamed.s0.pdst == renamed.s1.psrc2)));
wire both_mem = (db0.is_ld | db0.is_st) & (db1.is_ld | db1.is_st);
wire slot1_mem = db1.is_ld | db1.is_st;
// 分支只允许出现在执行槽 0。slot0 分支可以携带一个无访存的年轻
// slot1；若误预测，EX 在提交边界精确杀掉 slot1。这样恢复常见的
// branch+ALU 双发射，同时不再需要 slot1 分支解析器。
wire branch_pair_ok = ~db1.is_branch & ~(db0.is_branch & slot1_mem);
wire any_mul = db0.is_mul | db1.is_mul;
wire one_mul = db0.is_mul ^ db1.is_mul;
wire pure_alu0 = ~db0.is_mul & ~db0.is_cpucfg & ~db0.is_branch &
                 ~db0.is_ld & ~db0.is_st;
wire pure_alu1 = ~db1.is_mul & ~db1.is_cpucfg & ~db1.is_branch &
                 ~db1.is_ld & ~db1.is_st;
wire mul_pair_ok = ~any_mul |
                   (one_mul & ((db0.is_mul & pure_alu1) |
                               (db1.is_mul & pure_alu0)));
wire mul_block = any_mul & ~mul_pair_ok;

wire can_coissue = renamed.v1 & ~both_mem & branch_pair_ok & mul_pair_ok & ~intra_raw;
wire issuing_split = is_valid & ~slot1_pending & renamed.v1 & ~can_coissue;
wire group_last    = slot1_pending | ~issuing_split;

assign IS_to_RF_valid = is_valid;
assign IS_allow_in    = ~is_valid | (group_last & RF_allow_in);
wire   is_fire        = IS_to_RF_valid & RF_allow_in;

// 这些脉冲只描述一次真正完成的 IS 发射。多个 split 原因可以同时为 1，
// 便于区分“本次为何不能配对”；perf_split_total 则始终每个拆分 bundle 只计 1。
assign perf_coissue     = is_fire & ~slot1_pending & renamed.v1 & can_coissue;
assign perf_split_total = is_fire & issuing_split;
assign perf_split_raw   = is_fire & issuing_split & intra_raw;
assign perf_split_mem   = is_fire & issuing_split & both_mem;
assign perf_split_mul   = is_fire & issuing_split & mul_block;
assign perf_split_branch = is_fire & issuing_split & ~branch_pair_ok;

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

rr_to_dp_bus_t out_renamed;
always_comb begin
    if (slot1_pending) begin
        out_renamed.s0 = renamed.s1;
        out_renamed.s1 = renamed.s1;
        out_renamed.v1 = 1'b0;
    end else if (issuing_split) begin
        out_renamed.s0 = renamed.s0;
        out_renamed.s1 = renamed.s1;
        out_renamed.v1 = 1'b0;
    end else begin
        out_renamed = renamed;
    end
end

assign IS_to_RF_BUS = '{dp_to_is_bus: '{rr_to_dp_bus: out_renamed}};

endmodule
