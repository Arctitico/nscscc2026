// ============================================================================
// IS —— 8 项整数发射队列
//
// 纯 ALU 指令按物理源 tag 的 ready 状态唤醒，并可越过未就绪的更老纯
// ALU，最多选择两条送往 RF。8 个物理槽位之外另设一张仅保存槽号的
// 年龄顺序表，避免在发射关键路径上逐项比较 ROB 距离。分支、乘法、
// 访存和 cpucfg 作为顺序屏障：
// 它们只在成为队列最老项且源已就绪时发射；除 cpucfg 外可携带屏障后、
// 下一屏障前的一条独立纯 ALU，年轻纯 ALU 不单独越过屏障。
//
// 队列与 RF 之间使用一项 skid/hold：RF 可接收时选择结果直接进入 RF，
// 背压时才登记并保持载荷。IS_allow_in 仍只由已登记的 IQ 占用数决定，
// 不把 RF/EX/WB ready 组合传播回 DP。误预测冲刷 IQ 与 hold。
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

    input  rob_idx_t        rob_head_idx,
    input  wire             rename_alloc_fire,
    input  wire             rename_alloc_v1,
    input  rr_to_dp_bus_t   rename_alloc_bus,
    input  wire             complete_valid,
    input  wb_to_cm_bus_t   complete_bus,
    input  fwd_bus_t        ex_wakeup0,
    input  fwd_bus_t        ex_wakeup1,

    output wire             perf_coissue,
    output wire             perf_split_total,
    output wire             perf_split_raw,
    output wire             perf_split_mem,
    output wire             perf_split_mul,
    output wire             perf_split_branch,
    output wire             perf_ooo_issue,
    output wire             perf_iq_full
);

localparam int unsigned IQ_DEPTH = 8;
localparam int unsigned IQ_BITS  = $clog2(IQ_DEPTH);
localparam logic [3:0] IQ_DEPTH_W = 4'd8;

rr_slot_t iq_entry [0:IQ_DEPTH-1];
logic [IQ_DEPTH-1:0] iq_valid;
logic [3:0]          count;
logic [IQ_BITS-1:0]  age_order [0:IQ_DEPTH-1];

// p0-p31 是复位后的初始架构映射；新分配目的 tag 在 rename 当拍清 ready，
// WB 完成时再置 ready。释放 tag 的 ready 值无意义，下次分配会重新清零。
logic [PREG_COUNT-1:0] preg_ready;

function automatic logic completion_hit(input preg_t tag);
    completion_hit =
        (tag == preg_t'(0)) |
        (complete_valid & complete_bus.s0.rf_we &
         (complete_bus.s0.pdst == tag)) |
        (complete_valid & complete_bus.v1 & complete_bus.s1.rf_we &
         (complete_bus.s1.pdst == tag));
endfunction

function automatic logic ex_wakeup_hit(input preg_t tag);
    ex_wakeup_hit =
        (ex_wakeup0.valid & ex_wakeup0.rf_we & ~ex_wakeup0.is_ld &
         (ex_wakeup0.pdst == tag) & (tag != preg_t'(0))) |
        (ex_wakeup1.valid & ex_wakeup1.rf_we & ~ex_wakeup1.is_ld &
         (ex_wakeup1.pdst == tag) & (tag != preg_t'(0)));
endfunction

logic [IQ_DEPTH-1:0] iq_pure_alu;
logic [IQ_DEPTH-1:0] iq_ready;

generate
    for (genvar g = 0; g < IQ_DEPTH; g++) begin : gen_iq_status
        wire need1 = iq_entry[g].id.d_bus.need_rj;
        wire need2 = iq_entry[g].id.d_bus.need_rkd;
        wire src1_ready = ~need1 | preg_ready[iq_entry[g].psrc1] |
                          completion_hit(iq_entry[g].psrc1) |
                          ex_wakeup_hit(iq_entry[g].psrc1);
        wire src2_ready = ~need2 | preg_ready[iq_entry[g].psrc2] |
                          completion_hit(iq_entry[g].psrc2) |
                          ex_wakeup_hit(iq_entry[g].psrc2);
        wire serial_op = iq_entry[g].id.d_bus.is_branch |
                         iq_entry[g].id.d_bus.is_mul |
                         iq_entry[g].id.d_bus.is_cpucfg |
                         iq_entry[g].id.d_bus.is_ld |
                         iq_entry[g].id.d_bus.is_st;

        assign iq_pure_alu[g] = ~serial_op;
        assign iq_ready[g]    = src1_ready & src2_ready;
    end
endgenerate

// age_order 按程序顺序保存有效物理槽号。因此选择只需顺序扫描 8 个
// 3-bit 槽号，无需将 ROB head 扇出到所有槽位并级联距离比较器。
logic [IQ_DEPTH-1:0] select_mask;
logic [1:0]          select_count;
logic [IQ_BITS-1:0]  select_idx0;
logic [IQ_BITS-1:0]  select_idx1;
logic                select_ooo;
wire                 select_valid = (select_count != 2'd0);

logic first_found;
logic second_found;
logic pair_found;
logic before_barrier;
logic seen_unselected;
logic [IQ_BITS-1:0] scan_idx;

always_comb begin
    select_mask  = '0;
    select_count = 2'd0;
    select_idx0  = '0;
    select_idx1  = '0;
    select_ooo   = 1'b0;

    first_found  = 1'b0;
    second_found = 1'b0;
    pair_found   = 1'b0;
    before_barrier = 1'b1;
    seen_unselected = 1'b0;
    scan_idx = '0;

    // 最老项若是顺序屏障，先选择它；分支/乘法/单访存可再带独立 ALU。
    if ((count != 4'd0) && !iq_pure_alu[age_order[0]]) begin
        if (iq_ready[age_order[0]]) begin
            select_mask[age_order[0]] = 1'b1;
            select_idx0               = age_order[0];
            select_count            = 2'd1;

            // 恢复旧后端已经验证过的安全配对：最老分支、乘法或单访存
            // 可携带一条独立年轻 ALU。候选不越过下一个顺序屏障；
            // 分支误预测时 EX 会杀掉 slot1。cpucfg 仍保持单发。
            if (iq_entry[age_order[0]].id.d_bus.is_branch |
                iq_entry[age_order[0]].id.d_bus.is_mul |
                iq_entry[age_order[0]].id.d_bus.is_ld |
                iq_entry[age_order[0]].id.d_bus.is_st) begin
                for (int unsigned pos = 1; pos < IQ_DEPTH; pos++) begin
                    scan_idx = age_order[pos];
                    if ((pos < count) && before_barrier) begin
                        if (!iq_pure_alu[scan_idx]) begin
                            before_barrier = 1'b0;
                        end else if (iq_ready[scan_idx] && !pair_found) begin
                            pair_found = 1'b1;
                            select_mask[scan_idx] = 1'b1;
                            select_idx1 = scan_idx;
                        end
                    end
                end
                if (pair_found)
                    select_count          = 2'd2;
            end
        end
    end else begin
        // 从最老端扫到第一条顺序屏障，选择最老的两条 ready ALU。
        for (int unsigned pos = 0; pos < IQ_DEPTH; pos++) begin
            scan_idx = age_order[pos];
            if ((pos < count) && before_barrier) begin
                if (!iq_pure_alu[scan_idx]) begin
                    before_barrier = 1'b0;
                end else if (iq_ready[scan_idx] && !first_found) begin
                    first_found = 1'b1;
                    select_idx0 = scan_idx;
                    select_mask[scan_idx] = 1'b1;
                end else if (iq_ready[scan_idx] && !second_found) begin
                    second_found = 1'b1;
                    select_idx1  = scan_idx;
                    select_mask[scan_idx] = 1'b1;
                end
            end
        end

        if (first_found) begin
            select_count = 2'd1;
            if (second_found)
                select_count = 2'd2;
        end
    end

    // 若任一被选项前面仍留有未选的有效项，本拍发生真实乱序越过。
    for (int unsigned pos = 0; pos < IQ_DEPTH; pos++) begin
        scan_idx = age_order[pos];
        if (pos < count) begin
            if (select_mask[scan_idx] && seen_unselected)
                select_ooo = 1'b1;
            if (!select_mask[scan_idx])
                seen_unselected = 1'b1;
        end
    end
end

rr_to_dp_bus_t selected_bus;
is_to_rf_bus_t selected_out_bus;
always_comb begin
    selected_bus.s0 = iq_entry[select_idx0];
    selected_bus.s1 = iq_entry[select_idx1];
    selected_bus.v1 = (select_count == 2'd2);
    selected_out_bus = '{dp_to_is_bus: '{rr_to_dp_bus: selected_bus}};
end

logic          hold_valid;
is_to_rf_bus_t hold_bus;
wire direct_select = ~hold_valid & select_valid;
wire refill_hold   = hold_valid & RF_allow_in & select_valid;
wire capture_hold  = direct_select & ~RF_allow_in;
wire direct_fire   = direct_select & RF_allow_in;
wire select_fire   = (refill_hold | capture_hold | direct_fire) & ~flush;

always_ff @(posedge clk) begin
    if (reset | flush) begin
        hold_valid <= 1'b0;
    end else if (hold_valid) begin
        if (RF_allow_in) begin
            hold_valid <= select_valid;
            if (select_valid)
                hold_bus <= selected_out_bus;
        end
    end else if (capture_hold) begin
        hold_valid <= 1'b1;
        hold_bus   <= selected_out_bus;
    end
end

assign IS_to_RF_valid = hold_valid | select_valid;
assign IS_to_RF_BUS   = hold_valid ? hold_bus : selected_out_bus;

// IS_allow_in 仅看当前登记占用；满队列即使同拍发射也保守地下一拍再收。
wire [1:0] dispatch_need = DP_to_IS_BUS.rr_to_dp_bus.v1 ? 2'd2 : 2'd1;
wire [3:0] dispatch_need_w = {2'b0, dispatch_need};
assign IS_allow_in = ~flush &&
                     (count <= (IQ_DEPTH_W - dispatch_need_w));
wire dispatch_fire = DP_to_IS_valid & IS_allow_in;

logic [IQ_BITS-1:0] free_idx0;
logic [IQ_BITS-1:0] free_idx1;
logic free_found0;
logic free_found1;
always_comb begin
    free_idx0 = '0;
    free_idx1 = '0;
    free_found0 = 1'b0;
    free_found1 = 1'b0;
    for (int unsigned k = 0; k < IQ_DEPTH; k++) begin
        if (!iq_valid[k] && !free_found0) begin
            free_idx0 = IQ_BITS'(k);
            free_found0 = 1'b1;
        end else if (!iq_valid[k] && !free_found1) begin
            free_idx1 = IQ_BITS'(k);
            free_found1 = 1'b1;
        end
    end
end

wire [1:0] dispatch_count = dispatch_fire
                          ? (DP_to_IS_BUS.rr_to_dp_bus.v1 ? 2'd2 : 2'd1)
                          : 2'd0;
wire [1:0] issued_count = select_fire ? select_count : 2'd0;
wire [3:0] dispatch_count_w = {2'b0, dispatch_count};
wire [3:0] issued_count_w   = {2'b0, issued_count};

logic [IQ_BITS-1:0] age_order_next [0:IQ_DEPTH-1];
logic [3:0] compact_count;
always_comb begin
    for (int unsigned pos = 0; pos < IQ_DEPTH; pos++)
        age_order_next[pos] = '0;

    compact_count = 4'd0;
    for (int unsigned pos = 0; pos < IQ_DEPTH; pos++) begin
        if ((pos < count) &&
            !(select_fire && select_mask[age_order[pos]])) begin
            age_order_next[compact_count[IQ_BITS-1:0]] = age_order[pos];
            compact_count = compact_count + 4'd1;
        end
    end

    if (dispatch_fire) begin
        age_order_next[compact_count[IQ_BITS-1:0]] = free_idx0;
        compact_count = compact_count + 4'd1;
        if (DP_to_IS_BUS.rr_to_dp_bus.v1) begin
            age_order_next[compact_count[IQ_BITS-1:0]] = free_idx1;
            compact_count = compact_count + 4'd1;
        end
    end
end

always_ff @(posedge clk) begin
    if (reset | flush) begin
        iq_valid <= '0;
        count    <= 4'd0;
        for (int unsigned pos = 0; pos < IQ_DEPTH; pos++)
            age_order[pos] <= '0;
    end else begin
        count <= count + dispatch_count_w - issued_count_w;
        for (int unsigned pos = 0; pos < IQ_DEPTH; pos++)
            age_order[pos] <= age_order_next[pos];

        if (select_fire) begin
            for (int unsigned k = 0; k < IQ_DEPTH; k++) begin
                if (select_mask[k])
                    iq_valid[k] <= 1'b0;
            end
        end

        if (dispatch_fire) begin
            iq_valid[free_idx0] <= 1'b1;
            iq_entry[free_idx0] <= DP_to_IS_BUS.rr_to_dp_bus.s0;
            if (DP_to_IS_BUS.rr_to_dp_bus.v1) begin
                iq_valid[free_idx1] <= 1'b1;
                iq_entry[free_idx1] <= DP_to_IS_BUS.rr_to_dp_bus.s1;
            end
        end
    end
end

always_ff @(posedge clk) begin
    if (reset) begin
        preg_ready <= {{(PREG_COUNT-ARCH_REG_COUNT){1'b0}},
                       {ARCH_REG_COUNT{1'b1}}};
    end else begin
        if (complete_valid) begin
            if (complete_bus.s0.rf_we &&
                (complete_bus.s0.pdst != preg_t'(0)))
                preg_ready[complete_bus.s0.pdst] <= 1'b1;
            if (complete_bus.v1 && complete_bus.s1.rf_we &&
                (complete_bus.s1.pdst != preg_t'(0)))
                preg_ready[complete_bus.s1.pdst] <= 1'b1;
        end

        // 分配优先于同拍完成；free-list 不旁路同拍释放，正常情况下不会
        // 命中同一 tag，但明确优先级可保护后续接口演进。
        if (rename_alloc_fire) begin
            if (rename_alloc_bus.s0.id.d_bus.rf_we &&
                (rename_alloc_bus.s0.pdst != preg_t'(0)))
                preg_ready[rename_alloc_bus.s0.pdst] <= 1'b0;
            if (rename_alloc_v1 && rename_alloc_bus.s1.id.d_bus.rf_we &&
                (rename_alloc_bus.s1.pdst != preg_t'(0)))
                preg_ready[rename_alloc_bus.s1.pdst] <= 1'b0;
        end
    end
end

// 保留旧性能端口，coissue 改为 IQ 双选脉冲；固定 bundle 的 split 已不再
// 是有意义的统计。新增两个脉冲分别记录真实乱序越过和容量背压。
assign perf_coissue      = select_fire & (select_count == 2'd2);
assign perf_split_total  = 1'b0;
assign perf_split_raw    = 1'b0;
assign perf_split_mem    = 1'b0;
assign perf_split_mul    = 1'b0;
assign perf_split_branch = 1'b0;
assign perf_ooo_issue    = select_fire & select_ooo;
assign perf_iq_full      = DP_to_IS_valid & ~IS_allow_in;

// 兼容随机测试失败诊断中的层级观察名。
wire is_valid = (count != 4'd0) | hold_valid;

endmodule
