// Instruction-FIFO compaction profile for tb_perf.
//
// This simulation-only monitor mirrors DP's six metadata entries.  It tags
// every decoded instruction with its original ID bundle, then classifies each
// real greedy DP->IS group as:
//   * two instructions from the original bundle;
//   * two instructions compacted across a bundle boundary; or
//   * one instruction, with the exact pairing failure reasons.
//
// For the same dynamically issued instructions it also computes how many
// groups the old bundle-preserving scheduler would require.  This avoids using
// the old split_total counter as a proxy: a cross-boundary pair can consume an
// instruction that would otherwise have paired inside its own bundle.
import cpu_pkg::*;

module issue_compaction_profile #(
    parameter integer DEPTH = 6
) (
    input wire           clk,
    input wire           reset,
    input wire           marker_start,
    input wire           marker_end,
    input wire           flush,

    input wire           id_push,
    input wire           id_push_two,
    input id_to_dp_bus_t  id_bus,

    input wire           dp_pop,
    input wire           dp_take_two,
    input dp_to_is_bus_t  dp_bus,
    input wire [2:0]     dp_count
);

localparam integer PTR_W = $clog2(DEPTH);

reg [63:0] bundle_tag [0:DEPTH-1];
reg        original_slot1 [0:DEPTH-1];
reg        original_pairable [0:DEPTH-1];
reg [PTR_W-1:0] rd_ptr;
reg [PTR_W-1:0] wr_ptr;
reg [3:0] mirror_count;
reg [63:0] next_bundle_tag;

reg counting;
reg [63:0] instruction_count;
reg [63:0] greedy_group_count;
reg [63:0] bundle_group_count;
reg [63:0] dual_original;
reg [63:0] dual_cross;
reg [63:0] single_total;

// Overlapping reason bits: one single group may increment several counters.
reg [63:0] single_supply;
reg [63:0] single_raw;
reg [63:0] single_special;
reg [63:0] single_mem;
reg [63:0] single_mul;
reg [63:0] single_branch;
reg [63:0] single_b0_me1;

// Mutually exclusive primary reasons, in diagnostic priority order.
reg [63:0] primary_supply;
reg [63:0] primary_raw;
reg [63:0] primary_special;
reg [63:0] primary_b0_me1;
reg [63:0] primary_mem;
reg [63:0] primary_mul;
reg [63:0] primary_branch;
reg [63:0] primary_other;
reg        last_profile_valid;
reg [63:0] last_profile_tag;
reg        last_profile_was_slot0;

function automatic [PTR_W-1:0] ptr_add(
    input [PTR_W-1:0] ptr,
    input [1:0]       amount
);
    integer sum;
    begin
        sum = ptr + amount;
        if (sum >= DEPTH)
            sum = sum - DEPTH;
        ptr_add = sum[PTR_W-1:0];
    end
endfunction

id_to_dp_bus_t head;
d_bus_t head0;
d_bus_t head1;
wire [4:0] head1_rkd;
wire head0_writes;
wire head_raw;
wire head0_mem;
wire head1_mem;
wire head_both_mem;
wire head_both_mul;
wire head_both_branch;
wire head_b0_me1;
wire head_special;
wire head_both_alu;
wire head_fast_intra_raw;
wire head_pairable;

d_bus_t input0;
d_bus_t input1;
wire [4:0] input1_rkd;
wire input0_writes;
wire input_raw;
wire input0_mem;
wire input1_mem;
wire input_both_mem;
wire input_both_mul;
wire input_both_branch;
wire input_b0_me1;
wire input_special;
wire input_both_alu;
wire input_fast_intra_raw;

assign head = dp_bus.id_to_dp_bus;
assign head0 = head.s0.d_bus;
assign head1 = head.s1.d_bus;
assign head1_rkd = head1.src_reg_is_rd ? head1.rd : head1.rk;
assign head0_writes = head0.rf_we & (head0.rf_waddr != 5'b0);
assign head_raw = head0_writes &
                  ((head1.need_rj  & (head0.rf_waddr == head1.rj)) |
                   (head1.need_rkd & (head0.rf_waddr == head1_rkd)));
assign head0_mem = head0.is_ld | head0.is_st;
assign head1_mem = head1.is_ld | head1.is_st;
assign head_both_mem = head0_mem & head1_mem;
assign head_both_mul = head0.is_mul & head1.is_mul;
assign head_both_branch = head0.is_branch & head1.is_branch;
assign head_b0_me1 = head0.is_branch & head1_mem;
assign head_special = head0.is_cpucfg | head1.is_cpucfg;
assign head_both_alu = (|head0.alu_op) & (|head1.alu_op);
assign head_fast_intra_raw = head0.alu_op[8] &
                             (head1.alu_op[0] | head1.alu_op[7]);
assign head_pairable = head.v1 &
                       (~head_raw |
                        (head_both_alu & head_fast_intra_raw)) &
                       ~head_special &
                       ~head_both_mem & ~head_both_mul &
                       ~head_both_branch & ~head_b0_me1;

assign input0 = id_bus.s0.d_bus;
assign input1 = id_bus.s1.d_bus;
assign input1_rkd = input1.src_reg_is_rd ? input1.rd : input1.rk;
assign input0_writes = input0.rf_we & (input0.rf_waddr != 5'b0);
assign input_raw = input0_writes &
                   ((input1.need_rj  & (input0.rf_waddr == input1.rj)) |
                    (input1.need_rkd & (input0.rf_waddr == input1_rkd)));
assign input0_mem = input0.is_ld | input0.is_st;
assign input1_mem = input1.is_ld | input1.is_st;
assign input_both_mem = input0_mem & input1_mem;
assign input_both_mul = input0.is_mul & input1.is_mul;
assign input_both_branch = input0.is_branch & input1.is_branch;
assign input_b0_me1 = input0.is_branch & input1_mem;
assign input_special = input0.is_cpucfg | input1.is_cpucfg;
assign input_both_alu = (|input0.alu_op) & (|input1.alu_op);
assign input_fast_intra_raw = input0.alu_op[8] &
                              (input1.alu_op[0] | input1.alu_op[7]);

wire [1:0] pushed = id_push ? (id_push_two ? 2'd2 : 2'd1) : 2'd0;
wire [1:0] popped = dp_pop ? (dp_take_two ? 2'd2 : 2'd1) : 2'd0;
wire input_pairable = id_push_two &
                      (~input_raw |
                       (input_both_alu & input_fast_intra_raw)) &
                      ~input_special &
                      ~input_both_mem & ~input_both_mul &
                      ~input_both_branch & ~input_b0_me1;

wire [63:0] tag0 = bundle_tag[rd_ptr];
wire [63:0] tag1 = bundle_tag[ptr_add(rd_ptr, 2'd1)];
wire slot1_0 = original_slot1[rd_ptr];
wire slot1_1 = original_slot1[ptr_add(rd_ptr, 2'd1)];
wire pairable_0 = original_pairable[rd_ptr];
wire pairable_1 = original_pairable[ptr_add(rd_ptr, 2'd1)];
// A pairable slot1 contributes no old-scheduler group only when its slot0 was
// also counted inside the marker window.  This removes partial-bundle skew at
// the 0x06 boundary.
wire base_group0 = ~slot1_0 | ~pairable_0 |
                   ~last_profile_valid |
                   (last_profile_tag != tag0) |
                   ~last_profile_was_slot0;
wire base_group1 = ~slot1_1 | ~pairable_1 |
                   (tag0 != tag1) | slot1_0;

// Mirror only metadata; decoded instructions remain solely in the DUT.
always @(posedge clk) begin
    if (reset) begin
        rd_ptr          <= '0;
        wr_ptr          <= '0;
        mirror_count    <= 4'b0;
        next_bundle_tag <= 64'b0;
    end else if (flush) begin
        rd_ptr       <= '0;
        wr_ptr       <= '0;
        mirror_count <= 4'b0;
    end else begin
        mirror_count <= mirror_count + pushed - popped;
        if (id_push) begin
            bundle_tag[wr_ptr]        <= next_bundle_tag;
            original_slot1[wr_ptr]    <= 1'b0;
            original_pairable[wr_ptr] <= input_pairable;
            if (id_push_two) begin
                bundle_tag[ptr_add(wr_ptr, 2'd1)]        <= next_bundle_tag;
                original_slot1[ptr_add(wr_ptr, 2'd1)]    <= 1'b1;
                original_pairable[ptr_add(wr_ptr, 2'd1)] <= input_pairable;
            end
            wr_ptr          <= ptr_add(wr_ptr, pushed);
            next_bundle_tag <= next_bundle_tag + 64'd1;
        end
        if (dp_pop)
            rd_ptr <= ptr_add(rd_ptr, popped);
    end
end

// Check that the monitor follows the real DP queue exactly.
always @(posedge clk) begin
    if (!reset && !flush && (mirror_count != {1'b0, dp_count}))
        $fatal(1, "[ICOMPACT] metadata mirror mismatch monitor=%0d DP=%0d",
               mirror_count, dp_count);
    if (!reset && !flush && dp_pop && dp_take_two &&
        (mirror_count < 4'd2))
        $fatal(1, "[ICOMPACT] DP took two with only %0d mirrored entries",
               mirror_count);
    if (!reset && !flush && dp_pop && dp_take_two && (tag0 == tag1) &&
        (slot1_0 || !slot1_1 || !pairable_0 || !pairable_1))
        $fatal(1, "[ICOMPACT] invalid original-pair metadata tag=%0d slots=%0d/%0d pairable=%0d/%0d live=%0d raw=%0d special=%0d mem=%0d mul=%0d branch=%0d b0me1=%0d",
               tag0, slot1_0, slot1_1, pairable_0, pairable_1,
               head_pairable, head_raw, head_special,
               head_both_mem, head_both_mul, head_both_branch, head_b0_me1);
end

always @(posedge clk) begin
    if (reset) begin
        counting <= 1'b0;
        last_profile_valid <= 1'b0;
    end else if (marker_start) begin
        counting          <= 1'b1;
        instruction_count <= 64'b0;
        greedy_group_count <= 64'b0;
        bundle_group_count <= 64'b0;
        dual_original     <= 64'b0;
        dual_cross        <= 64'b0;
        single_total      <= 64'b0;
        single_supply     <= 64'b0;
        single_raw        <= 64'b0;
        single_special    <= 64'b0;
        single_mem        <= 64'b0;
        single_mul        <= 64'b0;
        single_branch     <= 64'b0;
        single_b0_me1     <= 64'b0;
        primary_supply    <= 64'b0;
        primary_raw       <= 64'b0;
        primary_special   <= 64'b0;
        primary_b0_me1    <= 64'b0;
        primary_mem       <= 64'b0;
        primary_mul       <= 64'b0;
        primary_branch    <= 64'b0;
        primary_other     <= 64'b0;
        last_profile_valid <= 1'b0;
    end else if (marker_end && counting) begin
        counting <= 1'b0;
        $display("[ICOMPACT] instructions=%0d greedy_groups=%0d bundle_groups=%0d saved_groups=%0d",
                 instruction_count, greedy_group_count, bundle_group_count,
                 bundle_group_count - greedy_group_count);
        $display("[ICOMPACT] dual_original=%0d dual_cross=%0d single=%0d",
                 dual_original, dual_cross, single_total);
        $display("[ICOMPACT] single_overlap supply=%0d raw=%0d special=%0d mem=%0d mul=%0d branch=%0d b0_me1=%0d",
                 single_supply, single_raw, single_special, single_mem,
                 single_mul, single_branch, single_b0_me1);
        $display("[ICOMPACT] single_primary supply=%0d raw=%0d special=%0d b0_me1=%0d mem=%0d mul=%0d branch=%0d other=%0d",
                 primary_supply, primary_raw, primary_special,
                 primary_b0_me1, primary_mem, primary_mul,
                 primary_branch, primary_other);
        if (greedy_group_count !=
            instruction_count - dual_original - dual_cross)
            $fatal(1, "[ICOMPACT] greedy group accounting mismatch");
        if (single_total != primary_supply + primary_raw +
            primary_special + primary_b0_me1 + primary_mem +
            primary_mul + primary_branch + primary_other)
            $fatal(1, "[ICOMPACT] primary single-reason accounting mismatch");
    end else if (flush && counting) begin
        last_profile_valid <= 1'b0;
    end else if (counting && dp_pop && !flush) begin
        greedy_group_count <= greedy_group_count + 64'd1;
        instruction_count <= instruction_count +
                             (dp_take_two ? 64'd2 : 64'd1);
        bundle_group_count <= bundle_group_count + base_group0 +
                              (dp_take_two ? base_group1 : 1'b0);
        last_profile_valid <= 1'b1;
        last_profile_tag <= dp_take_two ? tag1 : tag0;
        last_profile_was_slot0 <= dp_take_two ? ~slot1_1 : ~slot1_0;

        if (dp_take_two) begin
            if (tag0 == tag1)
                dual_original <= dual_original + 64'd1;
            else
                dual_cross <= dual_cross + 64'd1;
        end else begin
            single_total <= single_total + 64'd1;
            if (!head.v1) begin
                single_supply  <= single_supply + 64'd1;
                primary_supply <= primary_supply + 64'd1;
            end else begin
                if (head_raw)
                    single_raw <= single_raw + 64'd1;
                if (head_special)
                    single_special <= single_special + 64'd1;
                if (head_both_mem | head_b0_me1)
                    single_mem <= single_mem + 64'd1;
                if (head_both_mul)
                    single_mul <= single_mul + 64'd1;
                if (head_both_branch | head_b0_me1)
                    single_branch <= single_branch + 64'd1;
                if (head_b0_me1)
                    single_b0_me1 <= single_b0_me1 + 64'd1;

                if (head_raw)
                    primary_raw <= primary_raw + 64'd1;
                else if (head_special)
                    primary_special <= primary_special + 64'd1;
                else if (head_b0_me1)
                    primary_b0_me1 <= primary_b0_me1 + 64'd1;
                else if (head_both_mem)
                    primary_mem <= primary_mem + 64'd1;
                else if (head_both_mul)
                    primary_mul <= primary_mul + 64'd1;
                else if (head_both_branch)
                    primary_branch <= primary_branch + 64'd1;
                else
                    primary_other <= primary_other + 64'd1;
            end
        end
    end
end

endmodule

bind tb_perf issue_compaction_profile u_issue_compaction_profile (
    .clk(clk),
    .reset(reset),
    .marker_start(marker_start),
    .marker_end(marker_end),
    .flush(u_cpu.flush),
    .id_push(u_cpu.ID_to_DP_valid & u_cpu.DP_allow_in & ~u_cpu.flush),
    .id_push_two(u_cpu.ID_to_DP_BUS.v1),
    .id_bus(u_cpu.ID_to_DP_BUS),
    .dp_pop(u_cpu.DP_to_IS_valid & u_cpu.IS_allow_in & ~u_cpu.flush),
    .dp_take_two(u_cpu.IS_take_two),
    .dp_bus(u_cpu.DP_to_IS_BUS),
    .dp_count(u_cpu.u_DP.count)
);
