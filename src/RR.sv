// ============================================================================
// RR —— 双槽寄存器重命名
//
// speculative RAT 在接收 ID bundle 时按程序序更新：slot1 的源映射可看到
// slot0 的新目的 tag，因此同 bundle RAW/WAW 均有确定语义。ROB 提交更新
// committed RAT 并归还 old_pdst；分支误预测用 ROB 中的 RAT snapshot 恢复。
// ============================================================================
import cpu_pkg::*;

module RR (
    input  wire             clk,
    input  wire             reset,
    input  wire             flush,

    input  wire             ID_to_RR_valid,
    input  wire             DP_allow_in,
    output wire             RR_allow_in,
    output wire             RR_to_DP_valid,

    input  id_to_rr_bus_t   ID_to_RR_BUS,
    output rr_to_dp_bus_t   RR_to_DP_BUS,

    input  wire             rob_alloc_ready,
    input  rob_idx_t        rob_alloc_idx0,
    input  rob_idx_t        rob_alloc_idx1,
    output wire             rob_alloc_fire,
    output wire             rob_alloc_v1,
    output rr_to_dp_bus_t   rob_alloc_bus,
    output rat_snapshot_t   rob_alloc_rat0,
    output rat_snapshot_t   rob_alloc_rat1,

    input  rat_snapshot_t   recover_rat,
    input  wire [PREG_COUNT-1:0] recover_free_mask,

    input  wire             commit_valid,
    input  wb_to_cm_bus_t   commit_bus
);

reg            rr_valid;
rr_to_dp_bus_t rr_bus_r;
rat_snapshot_t speculative_rat;
rat_snapshot_t committed_rat;

d_bus_t in_db0;
d_bus_t in_db1;
assign in_db0 = ID_to_RR_BUS.s0.d_bus;
assign in_db1 = ID_to_RR_BUS.s1.d_bus;

wire in_dest0 = ID_to_RR_valid & in_db0.rf_we & (in_db0.rf_waddr != 5'd0);
wire in_dest1 = ID_to_RR_valid & ID_to_RR_BUS.v1 & in_db1.rf_we &
                (in_db1.rf_waddr != 5'd0);

wire free_alloc_ready;
wire free_alloc_valid0;
wire free_alloc_valid1;
preg_t free_alloc_preg0;
preg_t free_alloc_preg1;
wire [PREG_COUNT-1:0] free_bitmap;

wire commit_dest0 = commit_valid & commit_bus.s0.rf_we &
                    (commit_bus.s0.rf_waddr != 5'd0);
wire commit_dest1 = commit_valid & commit_bus.v1 & commit_bus.s1.rf_we &
                    (commit_bus.s1.rf_waddr != 5'd0);

wire rr_pop = rr_valid & DP_allow_in;
wire rr_slot_available = ~rr_valid | DP_allow_in;
wire rename_resources_ready = free_alloc_ready & rob_alloc_ready;
assign RR_allow_in = rr_slot_available &
                     (~ID_to_RR_valid | rename_resources_ready) & ~flush;
assign rob_alloc_fire = ID_to_RR_valid & RR_allow_in;
assign rob_alloc_v1 = ID_to_RR_BUS.v1;
assign RR_to_DP_valid = rr_valid;

wire [PREG_COUNT-1:0] restore_bitmap = free_bitmap | recover_free_mask;
preg_free_list u_free_list (
    .clk            (clk),
    .reset          (reset),
    .alloc_fire     (rob_alloc_fire),
    .alloc_req0     (in_dest0),
    .alloc_req1     (in_dest1),
    .alloc_ready    (free_alloc_ready),
    .alloc_valid0   (free_alloc_valid0),
    .alloc_preg0    (free_alloc_preg0),
    .alloc_valid1   (free_alloc_valid1),
    .alloc_preg1    (free_alloc_preg1),
    .free_valid0    (commit_dest0),
    .free_preg0     (commit_bus.s0.old_pdst),
    .free_valid1    (commit_dest1),
    .free_preg1     (commit_bus.s1.old_pdst),
    .restore_valid  (flush),
    .restore_bitmap (restore_bitmap),
    .free_bitmap    (free_bitmap)
);

rr_to_dp_bus_t renamed_next;
rat_snapshot_t rat_after0;
rat_snapshot_t rat_after1;
logic [4:0] src20;
logic [4:0] src21;
always_comb begin
    src20 = in_db0.src_reg_is_rd ? in_db0.rd : in_db0.rk;
    src21 = in_db1.src_reg_is_rd ? in_db1.rd : in_db1.rk;

    rat_after0 = speculative_rat;
    renamed_next.s0 = '{
        id: ID_to_RR_BUS.s0,
        psrc1: speculative_rat[in_db0.rj],
        psrc2: speculative_rat[src20],
        pdst: in_dest0 ? free_alloc_preg0 : preg_t'(0),
        old_pdst: speculative_rat[in_db0.rf_waddr],
        rob_idx: rob_alloc_idx0
    };
    if (in_dest0)
        rat_after0[in_db0.rf_waddr] = free_alloc_preg0;

    rat_after1 = rat_after0;
    renamed_next.s1 = '{
        id: ID_to_RR_BUS.s1,
        psrc1: rat_after0[in_db1.rj],
        psrc2: rat_after0[src21],
        pdst: in_dest1 ? free_alloc_preg1 : preg_t'(0),
        old_pdst: rat_after0[in_db1.rf_waddr],
        rob_idx: rob_alloc_idx1
    };
    if (in_dest1)
        rat_after1[in_db1.rf_waddr] = free_alloc_preg1;

    renamed_next.v1 = ID_to_RR_BUS.v1;
end

assign rob_alloc_bus = renamed_next;
assign rob_alloc_rat0 = rat_after0;
assign rob_alloc_rat1 = rat_after1;

always_ff @(posedge clk) begin
    if (reset | flush)
        rr_valid <= 1'b0;
    else begin
        case ({rob_alloc_fire, rr_pop})
        2'b10: rr_valid <= 1'b1;
        2'b01: rr_valid <= 1'b0;
        2'b11: rr_valid <= 1'b1;
        default: rr_valid <= rr_valid;
        endcase
    end
end

always_ff @(posedge clk) begin
    if (rob_alloc_fire) rr_bus_r <= renamed_next;
end

always_ff @(posedge clk) begin
    if (reset) begin
        for (int unsigned i = 0; i < ARCH_REG_COUNT; i++) begin
            speculative_rat[i] <= preg_t'(i);
            committed_rat[i]   <= preg_t'(i);
        end
    end else begin
        if (flush) begin
            speculative_rat <= recover_rat;
        end else if (rob_alloc_fire) begin
            speculative_rat <= ID_to_RR_BUS.v1 ? rat_after1 : rat_after0;
        end

        if (commit_dest0)
            committed_rat[commit_bus.s0.rf_waddr] <= commit_bus.s0.pdst;
        if (commit_dest1)
            committed_rat[commit_bus.s1.rf_waddr] <= commit_bus.s1.pdst;
    end
end

assign RR_to_DP_BUS = rr_bus_r;

endmodule
