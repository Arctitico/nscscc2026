// ============================================================================
// IS
//
// 定义以下五类指令：
// N：普通指令，包括使用到ALU的运算指令之类的。
// MU：乘法指令。
// B：分支指令。
// ME：访存指令。
// S：特殊指令，永远单发射。好像只有cpucfg，因为我们声称cache不存在。
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
    output wire             IS_take_two,
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
reg            split_r;
reg            split_raw_r;
reg            split_mem_r;
reg            split_mul_r;
reg            split_branch_r;

id_to_dp_bus_t idp;
assign idp = DP_to_IS_BUS.id_to_dp_bus;

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
wire loading_split = idp.v1 & ~can_coissue;

assign IS_to_RF_valid = is_valid;
assign IS_allow_in    = ~is_valid | RF_allow_in;
assign IS_take_two    = DP_to_IS_valid & IS_allow_in & can_coissue;
wire   is_fire        = IS_to_RF_valid & RF_allow_in;

// 这些脉冲只描述一次真正完成的 IS 发射。多个 split 原因可以同时为 1，
// 便于区分“本次为何不能配对”；perf_split_total 则始终每个拆分 bundle 只计 1。
assign perf_coissue      = is_fire & is_bus_r.id_to_dp_bus.v1;
assign perf_split_total  = is_fire & split_r;
assign perf_split_raw    = is_fire & split_raw_r;
assign perf_split_mem    = is_fire & split_mem_r;
assign perf_split_mul    = is_fire & split_mul_r;
assign perf_split_branch = is_fire & split_branch_r;

always @(posedge clk) begin
    if (reset)            is_valid <= 1'b0;
    else if (flush)       is_valid <= 1'b0;
    else if (IS_allow_in) is_valid <= DP_to_IS_valid;
end

dp_to_is_bus_t load_bus;
always_comb begin
    load_bus = DP_to_IS_BUS;
    load_bus.id_to_dp_bus.v1 = can_coissue;
end

always @(posedge clk) begin
    if (DP_to_IS_valid & IS_allow_in)
        is_bus_r <= load_bus;
end

always @(posedge clk) begin
    if (reset | flush) begin
        split_r        <= 1'b0;
        split_raw_r    <= 1'b0;
        split_mem_r    <= 1'b0;
        split_mul_r    <= 1'b0;
        split_branch_r <= 1'b0;
    end else if (DP_to_IS_valid & IS_allow_in) begin
        split_r        <= loading_split;
        split_raw_r    <= loading_split & intra_raw;
        split_mem_r    <= loading_split & (both_mem | branch_mem_bad);
        split_mul_r    <= loading_split & both_mul;
        split_branch_r <= loading_split & (both_branch | branch_mem_bad);
    end
end

assign IS_to_RF_BUS = '{dp_to_is_bus: is_bus_r};

endmodule
