// ============================================================================
// 16 项双分配/双完成/双提交 ROB
//
// 完成结果按 rob_idx 写回，提交只观察 ROB head；整数 ALU 已可由 IQ 乱序发射。
// 分支表项保存“执行完该分支后的 RAT snapshot”；误预测时保留到该分支，
// 释放所有年轻目的 tag，并把 tail 回退到 branch+1。
// ============================================================================
import cpu_pkg::*;

module rob (
    input  wire             clk,
    input  wire             reset,

    input  wire             alloc_fire,
    input  wire             alloc_v1,
    input  rr_to_dp_bus_t   alloc_bus,
    input  rat_snapshot_t   alloc_rat0,
    input  rat_snapshot_t   alloc_rat1,
    output wire             alloc_ready,
    output rob_idx_t        alloc_idx0,
    output rob_idx_t        alloc_idx1,
    output rob_idx_t        head_idx,

    input  wire             complete_valid,
    input  wb_to_cm_bus_t   complete_bus,

    input  wire             recover_valid,
    input  rob_idx_t        recover_idx,
    output rat_snapshot_t   recover_rat,
    output wire [PREG_COUNT-1:0] recover_free_mask,

    input  wire             commit_allow,
    output wire             commit_valid,
    output wb_to_cm_bus_t   commit_bus
);

typedef struct packed {
    logic          valid;
    logic          ready;
    logic [31:0]   pc;
    logic [31:0]   inst;
    logic [31:0]   value;
    logic          rf_we;
    logic [4:0]    arf_dest;
    preg_t         pdst;
    preg_t         old_pdst;
    logic          is_branch;
    rat_snapshot_t rat_after;
} rob_entry_t;

rob_entry_t entries [0:ROB_COUNT-1];
rob_idx_t head;
rob_idx_t tail;
logic [ROB_BITS:0] count;

wire [1:0] alloc_num = alloc_fire ? (alloc_v1 ? 2'd2 : 2'd1) : 2'd0;
wire [ROB_BITS:0] alloc_need = alloc_v1 ? 2 : 1;
wire [ROB_BITS:0] alloc_num_w = {{(ROB_BITS-1){1'b0}}, alloc_num};
localparam logic [ROB_BITS:0] ROB_COUNT_W = {1'b1, {ROB_BITS{1'b0}}};
assign alloc_ready = (count <= ROB_COUNT_W - alloc_need);
assign alloc_idx0 = tail;
assign alloc_idx1 = tail + rob_idx_t'(1);
assign head_idx   = head;

wire rob_idx_t head1 = head + rob_idx_t'(1);
wire head0_ready = (count != 0) && entries[head].valid && entries[head].ready;
wire head1_ready = (count > 1) && entries[head1].valid && entries[head1].ready;
wire commit0 = ~recover_valid & head0_ready;
wire commit1 = commit0 & head1_ready;
assign commit_valid = commit0;

assign commit_bus = '{
    s0: '{pc: entries[head].pc, inst: entries[head].inst,
          rf_wdata: entries[head].value, rf_we: entries[head].rf_we,
          rf_waddr: entries[head].arf_dest, pdst: entries[head].pdst,
          old_pdst: entries[head].old_pdst, rob_idx: head},
    s1: '{pc: entries[head1].pc, inst: entries[head1].inst,
          rf_wdata: entries[head1].value, rf_we: entries[head1].rf_we,
          rf_waddr: entries[head1].arf_dest, pdst: entries[head1].pdst,
          old_pdst: entries[head1].old_pdst, rob_idx: head1},
    v1: commit1
};

wire commit_fire = commit_valid & commit_allow;
wire [1:0] commit_num = commit_fire ? (commit1 ? 2'd2 : 2'd1) : 2'd0;
wire [ROB_BITS:0] commit_num_w = {{(ROB_BITS-1){1'b0}}, commit_num};

assign recover_rat = entries[recover_idx].rat_after;

logic [PREG_COUNT-1:0] recover_free_mask_r;
logic [ROB_BITS:0] recover_keep_count;
always_comb begin
    recover_free_mask_r = '0;
    recover_keep_count = {1'b0, recover_idx - head} + 1'b1;
    for (int unsigned i = 0; i < ROB_COUNT; i++) begin
        if (entries[i].valid &&
            ({1'b0, rob_idx_t'(i) - head} >= recover_keep_count) &&
            entries[i].rf_we && (entries[i].arf_dest != 5'd0) &&
            (entries[i].pdst != preg_t'(0))) begin
            recover_free_mask_r[entries[i].pdst] = 1'b1;
        end
    end
end
assign recover_free_mask = recover_free_mask_r;

always_ff @(posedge clk) begin
    if (reset) begin
        head  <= '0;
        tail  <= '0;
        count <= '0;
        for (int unsigned i = 0; i < ROB_COUNT; i++) begin
            entries[i].valid <= 1'b0;
            entries[i].ready <= 1'b0;
        end
    end else if (recover_valid) begin
        tail  <= recover_idx + rob_idx_t'(1);
        count <= recover_keep_count;
        for (int unsigned i = 0; i < ROB_COUNT; i++) begin
            if (entries[i].valid &&
                ({1'b0, rob_idx_t'(i) - head} >= recover_keep_count)) begin
                entries[i].valid <= 1'b0;
                entries[i].ready <= 1'b0;
            end
        end

        // redirect 与更老 WB 完成可能同拍；存活表项仍必须收到完成结果。
        if (complete_valid) begin
            entries[complete_bus.s0.rob_idx].ready <= 1'b1;
            entries[complete_bus.s0.rob_idx].value <= complete_bus.s0.rf_wdata;
            if (complete_bus.v1) begin
                entries[complete_bus.s1.rob_idx].ready <= 1'b1;
                entries[complete_bus.s1.rob_idx].value <= complete_bus.s1.rf_wdata;
            end
        end
    end else begin
        count <= count + alloc_num_w - commit_num_w;
        if (alloc_fire) tail <= tail + (alloc_v1 ? rob_idx_t'(2) : rob_idx_t'(1));
        if (commit_fire) head <= head + (commit1 ? rob_idx_t'(2) : rob_idx_t'(1));

        if (commit_fire) begin
            entries[head].valid <= 1'b0;
            entries[head].ready <= 1'b0;
            if (commit1) begin
                entries[head1].valid <= 1'b0;
                entries[head1].ready <= 1'b0;
            end
        end

        if (alloc_fire) begin
            entries[alloc_idx0].valid      <= 1'b1;
            entries[alloc_idx0].ready      <= 1'b0;
            entries[alloc_idx0].pc         <= alloc_bus.s0.id.pc;
            entries[alloc_idx0].inst       <= alloc_bus.s0.id.inst;
            entries[alloc_idx0].rf_we      <= alloc_bus.s0.id.d_bus.rf_we;
            entries[alloc_idx0].arf_dest   <= alloc_bus.s0.id.d_bus.rf_waddr;
            entries[alloc_idx0].pdst       <= alloc_bus.s0.pdst;
            entries[alloc_idx0].old_pdst   <= alloc_bus.s0.old_pdst;
            entries[alloc_idx0].is_branch  <= alloc_bus.s0.id.d_bus.is_branch;
            entries[alloc_idx0].rat_after  <= alloc_rat0;
            if (alloc_v1) begin
                entries[alloc_idx1].valid      <= 1'b1;
                entries[alloc_idx1].ready      <= 1'b0;
                entries[alloc_idx1].pc         <= alloc_bus.s1.id.pc;
                entries[alloc_idx1].inst       <= alloc_bus.s1.id.inst;
                entries[alloc_idx1].rf_we      <= alloc_bus.s1.id.d_bus.rf_we;
                entries[alloc_idx1].arf_dest   <= alloc_bus.s1.id.d_bus.rf_waddr;
                entries[alloc_idx1].pdst       <= alloc_bus.s1.pdst;
                entries[alloc_idx1].old_pdst   <= alloc_bus.s1.old_pdst;
                entries[alloc_idx1].is_branch  <= alloc_bus.s1.id.d_bus.is_branch;
                entries[alloc_idx1].rat_after  <= alloc_rat1;
            end
        end

        if (complete_valid) begin
            entries[complete_bus.s0.rob_idx].ready <= 1'b1;
            entries[complete_bus.s0.rob_idx].value <= complete_bus.s0.rf_wdata;
            if (complete_bus.v1) begin
                entries[complete_bus.s1.rob_idx].ready <= 1'b1;
                entries[complete_bus.s1.rob_idx].value <= complete_bus.s1.rf_wdata;
            end
        end
    end
end

endmodule
