// ============================================================================
// IS
//
// | slot0/slot1 | N | MU | B | ME | S |
// |-------------|---|----|---|----|---|
// | N           | y | y  | 1 | y  | n |
// | MU          | y | n  | 13| 3  | n |
// | B           | 2 | 23 | n | n  | n |
// | ME          | y | 3  | 1 | n  | n |
// | S           | n | n  | n | n  | n |
//
// slot0 是较老的指令，slot1 是较新的指令。也就是说如果是顺序单发射，先执行的是slot0的指令，后执行的是slot1的指令。
// 在设计上，slot0和slot1是紧密相连的，pc的delta仅为4.
//
// y：支持。
// n：不支持。
// 1：需要处理slot1分支解析的问题
// 2：slot0 分支误预测才杀 slot1
// 3：两个长延迟/握手型单元可能在不同拍完成，需要保存先完成的一侧
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
