// ============================================================================
// IS —— 顺序双发射的 co-issue 决策点。
//
// 两槽同拍发射需要同时满足：slot0 不是分支、最多一条访存、最多一条
// mul.w，且 slot1 不读 slot0 的目的寄存器。不满足时先发 slot0，再把
// slot1 重贴为单槽发射。暂不与下一 bundle 做 compaction。
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
    output is_to_rf_bus_t   IS_to_RF_BUS
);

reg            is_valid;
dp_to_is_bus_t is_bus_r;
reg            slot1_pending;

id_to_rr_bus_t idp;
assign idp = is_bus_r.rr_to_dp_bus.id_to_rr_bus;

d_bus_t db0;
d_bus_t db1;
assign db0 = idp.s0.d_bus;
assign db1 = idp.s1.d_bus;

wire        s0_writes = db0.rf_we & (db0.rf_waddr != 5'b0);
wire [ 4:0] s1_rkd    = db1.src_reg_is_rd ? db1.rd : db1.rk;
wire        intra_raw = s0_writes &
                        ((db1.need_rj  & (db0.rf_waddr == db1.rj)) |
                         (db1.need_rkd & (db0.rf_waddr == s1_rkd)));
wire both_mem = (db0.is_ld | db0.is_st) & (db1.is_ld | db1.is_st);
// mul.w 会在 EX 停留多拍；当前不让它与另一槽绑定，避免访存回包或
// 分支重定向在乘法等待期间重复发生。
wire any_mul = db0.is_mul | db1.is_mul;

wire can_coissue = idp.v1 & ~db0.is_branch & ~both_mem & ~any_mul & ~intra_raw;
wire issuing_split = is_valid & ~slot1_pending & idp.v1 & ~can_coissue;
wire group_last    = slot1_pending | ~issuing_split;

assign IS_to_RF_valid = is_valid;
assign IS_allow_in    = ~is_valid | (group_last & RF_allow_in);
wire   is_fire        = IS_to_RF_valid & RF_allow_in;

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

id_to_rr_bus_t out_idp;
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

assign IS_to_RF_BUS = '{dp_to_is_bus: '{rr_to_dp_bus: '{id_to_rr_bus: out_idp}}};

endmodule
