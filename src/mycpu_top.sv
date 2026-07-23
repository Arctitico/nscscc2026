// ============================================================================
// mycpu_top 
//
// 九级流水：IF → ID → RR → DP → IS → RF → EX → WB → CM
//          取指 译码 重命名 分发 发射 读寄存器 执行 写回 提交
//
// 当前已接入 8 项整数 IQ：纯 ALU 可按物理 tag ready 状态乱序双发；
// 分支、乘法、访存和 cpucfg 仍作为保守屏障单发。
// ============================================================================
import cpu_pkg::*;

module mycpu_top(
    input  wire        clk,
    input  wire        resetn,

    output wire        inst_rd_req,
    output wire [31:0] inst_rd_addr,
    input  wire        inst_rd_rdy,
    input  wire        inst_ret_valid,
    input  wire [31:0] inst_ret_data,
    input  wire        inst_ret_last,

    output wire        data_rd_req,
    output wire [ 2:0] data_rd_size,
    output wire [31:0] data_rd_addr,
    input  wire [31:0] data_rd_data,
    input  wire        data_rd_ok,

    output wire        data_wr_req,
    output wire [ 2:0] data_wr_size,
    output wire [31:0] data_wr_addr,
    output wire [ 3:0] data_wr_strb,
    output wire [31:0] data_wr_data,
    input  wire        data_wr_ok,

    output wire [31:0] debug_wb_pc,
    output wire [31:0] debug_wb_inst,
    output wire [ 3:0] debug_wb_rf_we,
    output wire [ 4:0] debug_wb_rf_wnum,
    output wire [31:0] debug_wb_rf_wdata,
    output wire [31:0] debug_wb1_pc,
    output wire [31:0] debug_wb1_inst,
    output wire [ 3:0] debug_wb1_rf_we,
    output wire [ 4:0] debug_wb1_rf_wnum,
    output wire [31:0] debug_wb1_rf_wdata
);

wire reset = ~resetn;

wire IF_to_ID_valid;
wire ID_to_RR_valid;
wire RR_to_DP_valid;
wire DP_to_IS_valid;
wire IS_to_RF_valid;
wire RF_to_EX_valid;
wire EX_to_WB_valid;
wire WB_to_ROB_valid;
wire ROB_to_CM_valid;

wire ID_allow_in;
wire RR_allow_in;
wire DP_allow_in;
wire IS_allow_in;
wire RF_allow_in;
wire EX_allow_in;
wire WB_allow_in;
wire CM_allow_in;

if_to_id_bus_t IF_to_ID_BUS;
id_to_rr_bus_t ID_to_RR_BUS;
rr_to_dp_bus_t RR_to_DP_BUS;
dp_to_is_bus_t DP_to_IS_BUS;
is_to_rf_bus_t IS_to_RF_BUS;
rf_to_ex_bus_t RF_to_EX_BUS;
ex_to_wb_bus_t EX_to_WB_BUS;
wb_to_cm_bus_t WB_to_ROB_BUS;
wb_to_cm_bus_t ROB_to_CM_BUS;

wire [31:0] bp_pc0;
wire        bp_taken0, bp_taken1;
wire [31:0] bp_target0, bp_target1;

wire        redirect;
wire [31:0] redirect_target;
rob_idx_t   redirect_rob_idx;
wire        flush = redirect;

wire        bp_upd_en;
wire [31:0] bp_upd_pc;
wire        bp_upd_taken;
wire        bp_upd_is_cond;
wire [31:0] bp_upd_target;

fwd_bus_t ex_fwd0, ex_fwd1;
fwd_bus_t wb_fwd0, wb_fwd1;
fwd_bus_t cm_fwd0, cm_fwd1;

preg_t rf_raddr1, rf_raddr2, rf_raddr3, rf_raddr4;
wire [31:0] rf_rdata1, rf_rdata2, rf_rdata3, rf_rdata4;
wire [ 3:0] rf_we1, rf_we2;
preg_t rf_waddr1, rf_waddr2;
wire [31:0] rf_wdata1, rf_wdata2;
wire [ 3:0] cm_rf_we1, cm_rf_we2;
preg_t cm_rf_waddr1, cm_rf_waddr2;
wire [31:0] cm_rf_wdata1, cm_rf_wdata2;

wire           rob_alloc_ready;
rob_idx_t      rob_alloc_idx0, rob_alloc_idx1;
rob_idx_t      rob_head_idx;
wire           rob_alloc_fire;
wire           rob_alloc_v1;
rr_to_dp_bus_t rob_alloc_bus;
rat_snapshot_t rob_alloc_rat0, rob_alloc_rat1;
rat_snapshot_t recover_rat;
wire [PREG_COUNT-1:0] recover_free_mask;

wire        ic_req;
wire [31:0] ic_addr;
wire        ic_addr_ok;
wire        ic_data_ok;
wire [31:0] ic_rdata_lo, ic_rdata_hi;
wire        ic_mem_rd_req;

wire        ex_data_sram_en;
wire [ 3:0] ex_data_sram_we;
wire [ 2:0] ex_data_sram_size;
wire [31:0] ex_data_sram_addr;
wire [31:0] ex_data_sram_wdata;
wire [31:0] ex_data_sram_rdata;
wire        ex_data_addr_ok;
wire        ex_data_ok;
wire        dcache_inst_safe;

wire perf_coissue_event;
wire perf_split_total_event;
wire perf_split_raw_event;
wire perf_split_mem_event;
wire perf_split_mul_event;
wire perf_split_branch_event;
wire perf_ooo_issue_event;
wire perf_iq_full_event;
wire perf_icache_miss_event;
wire perf_dcache_hit_event;
wire perf_dcache_miss_event;
wire perf_wb_stall_event;
wire perf_ex_addr_wait_event;
wire perf_wb_data_wait_event;
wire perf_data_wait_event = perf_ex_addr_wait_event | perf_wb_data_wait_event;
wire perf_mul_wait_event;
wire perf_branch_mispred_event;

// ============================ 流水级例化 ============================
IF u_IF (
    .clk             (clk             ),
    .reset           (reset           ),
    .IF_to_ID_valid  (IF_to_ID_valid  ),
    .ID_allow_in     (ID_allow_in     ),
    .IF_to_ID_BUS    (IF_to_ID_BUS    ),
    .bp_pc0          (bp_pc0          ),
    .bp_taken0       (bp_taken0       ),
    .bp_target0      (bp_target0      ),
    .bp_taken1       (bp_taken1       ),
    .bp_target1      (bp_target1      ),
    .redirect        (redirect        ),
    .redirect_target (redirect_target ),
    .ic_req          (ic_req          ),
    .ic_addr         (ic_addr         ),
    .ic_addr_ok      (ic_addr_ok      ),
    .ic_data_ok      (ic_data_ok      ),
    .ic_rdata_lo     (ic_rdata_lo     ),
    .ic_rdata_hi     (ic_rdata_hi     )
);

ID u_ID (
    .clk           (clk           ),
    .reset         (reset         ),
    .flush         (flush         ),
    .IF_to_ID_valid(IF_to_ID_valid),
    .RR_allow_in   (RR_allow_in   ),
    .ID_allow_in   (ID_allow_in   ),
    .ID_to_RR_valid(ID_to_RR_valid),
    .IF_to_ID_BUS  (IF_to_ID_BUS  ),
    .ID_to_RR_BUS  (ID_to_RR_BUS  )
);

RR u_RR (
    .clk           (clk           ),
    .reset         (reset         ),
    .flush         (flush         ),
    .ID_to_RR_valid(ID_to_RR_valid),
    .DP_allow_in   (DP_allow_in   ),
    .RR_allow_in   (RR_allow_in   ),
    .RR_to_DP_valid(RR_to_DP_valid),
    .ID_to_RR_BUS  (ID_to_RR_BUS  ),
    .RR_to_DP_BUS  (RR_to_DP_BUS  ),
    .rob_alloc_ready(rob_alloc_ready),
    .rob_alloc_idx0(rob_alloc_idx0),
    .rob_alloc_idx1(rob_alloc_idx1),
    .rob_alloc_fire(rob_alloc_fire),
    .rob_alloc_v1 (rob_alloc_v1),
    .rob_alloc_bus(rob_alloc_bus),
    .rob_alloc_rat0(rob_alloc_rat0),
    .rob_alloc_rat1(rob_alloc_rat1),
    .recover_rat  (recover_rat),
    .recover_free_mask(recover_free_mask),
    .commit_valid (ROB_to_CM_valid),
    .commit_bus   (ROB_to_CM_BUS)
);

DP u_DP (
    .clk           (clk           ),
    .reset         (reset         ),
    .flush         (flush         ),
    .RR_to_DP_valid(RR_to_DP_valid),
    .IS_allow_in   (IS_allow_in   ),
    .DP_allow_in   (DP_allow_in   ),
    .DP_to_IS_valid(DP_to_IS_valid),
    .RR_to_DP_BUS  (RR_to_DP_BUS  ),
    .DP_to_IS_BUS  (DP_to_IS_BUS  )
);

IS u_IS (
    .clk               (clk                    ),
    .reset             (reset                  ),
    .flush             (flush                  ),
    .DP_to_IS_valid    (DP_to_IS_valid         ),
    .RF_allow_in       (RF_allow_in            ),
    .IS_allow_in       (IS_allow_in            ),
    .IS_to_RF_valid    (IS_to_RF_valid         ),
    .DP_to_IS_BUS      (DP_to_IS_BUS           ),
    .IS_to_RF_BUS      (IS_to_RF_BUS           ),
    .rob_head_idx      (rob_head_idx            ),
    .rename_alloc_fire (rob_alloc_fire          ),
    .rename_alloc_v1   (rob_alloc_v1            ),
    .rename_alloc_bus  (rob_alloc_bus           ),
    .complete_valid    (WB_to_ROB_valid         ),
    .complete_bus      (WB_to_ROB_BUS           ),
    .ex_wakeup0        (ex_fwd0                 ),
    .ex_wakeup1        (ex_fwd1                 ),

    .perf_coissue      (perf_coissue_event     ),
    .perf_split_total  (perf_split_total_event ),
    .perf_split_raw    (perf_split_raw_event   ),
    .perf_split_mem    (perf_split_mem_event   ),
    .perf_split_mul    (perf_split_mul_event   ),
    .perf_split_branch (perf_split_branch_event),
    .perf_ooo_issue    (perf_ooo_issue_event   ),
    .perf_iq_full      (perf_iq_full_event     )
);

RF u_RF (
    .clk           (clk           ),
    .reset         (reset         ),
    .flush         (flush         ),
    .IS_to_RF_valid(IS_to_RF_valid),
    .EX_allow_in   (EX_allow_in   ),
    .RF_allow_in   (RF_allow_in   ),
    .RF_to_EX_valid(RF_to_EX_valid),
    .IS_to_RF_BUS  (IS_to_RF_BUS  ),
    .RF_to_EX_BUS  (RF_to_EX_BUS  ),
    .rf_raddr1     (rf_raddr1     ),
    .rf_raddr2     (rf_raddr2     ),
    .rf_raddr3     (rf_raddr3     ),
    .rf_raddr4     (rf_raddr4     ),
    .rf_rdata1     (rf_rdata1     ),
    .rf_rdata2     (rf_rdata2     ),
    .rf_rdata3     (rf_rdata3     ),
    .rf_rdata4     (rf_rdata4     ),
    .ex_fwd0       (ex_fwd0       ),
    .ex_fwd1       (ex_fwd1       ),
    .wb_fwd0       (wb_fwd0       ),
    .wb_fwd1       (wb_fwd1       ),
    .cm_fwd0       (cm_fwd0       ),
    .cm_fwd1       (cm_fwd1       )
);

EX u_EX (
    .clk            (clk                ),
    .reset          (reset              ),
    .RF_to_EX_valid (RF_to_EX_valid     ),
    .WB_allow_in    (WB_allow_in        ),
    .EX_allow_in    (EX_allow_in        ),
    .EX_to_WB_valid (EX_to_WB_valid     ),
    .RF_to_EX_BUS   (RF_to_EX_BUS       ),
    .EX_to_WB_BUS   (EX_to_WB_BUS       ),
    .redirect       (redirect           ),
    .redirect_target(redirect_target    ),
    .redirect_rob_idx(redirect_rob_idx  ),
    .bp_upd_en      (bp_upd_en          ),
    .bp_upd_pc      (bp_upd_pc          ),
    .bp_upd_taken   (bp_upd_taken       ),
    .bp_upd_is_cond (bp_upd_is_cond     ),
    .bp_upd_target  (bp_upd_target      ),
    .ex_fwd0        (ex_fwd0            ),
    .ex_fwd1        (ex_fwd1            ),
    .data_sram_en   (ex_data_sram_en    ),
    .data_sram_we   (ex_data_sram_we    ),
    .data_sram_size (ex_data_sram_size  ),
    .data_sram_addr (ex_data_sram_addr  ),
    .data_sram_wdata(ex_data_sram_wdata ),
    .data_addr_ok   (ex_data_addr_ok    ),

    .perf_data_wait      (perf_ex_addr_wait_event   ),
    .perf_mul_wait       (perf_mul_wait_event       ),
    .perf_branch_mispred (perf_branch_mispred_event )
);

WB u_WB (
    .clk            (clk                    ),
    .reset          (reset                  ),
    .EX_to_WB_valid (EX_to_WB_valid         ),
    .CM_allow_in    (CM_allow_in            ),
    .WB_allow_in    (WB_allow_in            ),
    .WB_to_CM_valid (WB_to_ROB_valid        ),
    .EX_to_WB_BUS   (EX_to_WB_BUS           ),
    .WB_to_CM_BUS   (WB_to_ROB_BUS          ),
    .data_sram_rdata(ex_data_sram_rdata     ),
    .data_ok        (ex_data_ok             ),
    .wb_fwd0        (wb_fwd0                ),
    .wb_fwd1        (wb_fwd1                ),
    .perf_data_wait (perf_wb_data_wait_event)
);

rob u_rob (
    .clk              (clk),
    .reset            (reset),
    .alloc_fire       (rob_alloc_fire),
    .alloc_v1         (rob_alloc_v1),
    .alloc_bus        (rob_alloc_bus),
    .alloc_rat0       (rob_alloc_rat0),
    .alloc_rat1       (rob_alloc_rat1),
    .alloc_ready      (rob_alloc_ready),
    .alloc_idx0       (rob_alloc_idx0),
    .alloc_idx1       (rob_alloc_idx1),
    .head_idx         (rob_head_idx),
    .complete_valid   (WB_to_ROB_valid),
    .complete_bus     (WB_to_ROB_BUS),
    .recover_valid    (redirect),
    .recover_idx      (redirect_rob_idx),
    .recover_rat      (recover_rat),
    .recover_free_mask(recover_free_mask),
    .commit_allow     (CM_allow_in),
    .commit_valid     (ROB_to_CM_valid),
    .commit_bus       (ROB_to_CM_BUS)
);

CM u_CM (
    .clk               (clk               ),
    .reset             (reset             ),
    .WB_to_CM_valid    (ROB_to_CM_valid   ),
    .CM_allow_in       (CM_allow_in       ),
    .WB_to_CM_BUS      (ROB_to_CM_BUS     ),
    .rf_we1            (cm_rf_we1         ),
    .rf_waddr1         (cm_rf_waddr1      ),
    .rf_wdata1         (cm_rf_wdata1      ),
    .rf_we2            (cm_rf_we2         ),
    .rf_waddr2         (cm_rf_waddr2      ),
    .rf_wdata2         (cm_rf_wdata2      ),
    .cm_fwd0           (cm_fwd0           ),
    .cm_fwd1           (cm_fwd1           ),
    .debug_wb_pc       (debug_wb_pc       ),
    .debug_wb_inst     (debug_wb_inst     ),
    .debug_wb_rf_we    (debug_wb_rf_we    ),
    .debug_wb_rf_wnum  (debug_wb_rf_wnum  ),
    .debug_wb_rf_wdata (debug_wb_rf_wdata ),
    .debug_wb1_pc      (debug_wb1_pc      ),
    .debug_wb1_inst    (debug_wb1_inst    ),
    .debug_wb1_rf_we   (debug_wb1_rf_we   ),
    .debug_wb1_rf_wnum (debug_wb1_rf_wnum ),
    .debug_wb1_rf_wdata(debug_wb1_rf_wdata)
);

// PRF 在完成时写入，ROB 只控制架构提交。这样结果离开 WB 后仍可由后续
// 指令从 PRF 读取，不依赖额外的 ROB->RF 旁路。
assign rf_we1    = {4{WB_to_ROB_valid & WB_to_ROB_BUS.s0.rf_we}};
assign rf_waddr1 = WB_to_ROB_BUS.s0.pdst;
assign rf_wdata1 = WB_to_ROB_BUS.s0.rf_wdata;
assign rf_we2    = {4{WB_to_ROB_valid & WB_to_ROB_BUS.v1 &
                      WB_to_ROB_BUS.s1.rf_we}};
assign rf_waddr2 = WB_to_ROB_BUS.s1.pdst;
assign rf_wdata2 = WB_to_ROB_BUS.s1.rf_wdata;

// ============================ 寄存器堆 ============================
regfile u_regfile (
    .clk      (clk      ),
    .rf_raddr1(rf_raddr1), .rf_rdata1(rf_rdata1),
    .rf_raddr2(rf_raddr2), .rf_rdata2(rf_rdata2),
    .rf_raddr3(rf_raddr3), .rf_rdata3(rf_rdata3),
    .rf_raddr4(rf_raddr4), .rf_rdata4(rf_rdata4),
    .rf_we1   (rf_we1   ), .rf_waddr1(rf_waddr1), .rf_wdata1(rf_wdata1),
    .rf_we2   (rf_we2   ), .rf_waddr2(rf_waddr2), .rf_wdata2(rf_wdata2)
);

// ============================ 分支预测 ============================
bpu u_bpu (
    .clk          (clk           ),
    .reset        (reset         ),
    .pred_pc0     (bp_pc0        ),
    .pred_taken0  (bp_taken0     ),
    .pred_target0 (bp_target0    ),
    .pred_taken1  (bp_taken1     ),
    .pred_target1 (bp_target1    ),
    .upd_en       (bp_upd_en     ),
    .upd_pc       (bp_upd_pc     ),
    .upd_taken    (bp_upd_taken  ),
    .upd_is_cond  (bp_upd_is_cond),
    .upd_target   (bp_upd_target )
);

// ============================ 数据缓存 ============================
dcache u_dcache (
    .clk          (clk                   ),
    .reset        (reset                 ),
    .cpu_req      (ex_data_sram_en       ),
    .cpu_we       (ex_data_sram_we       ),
    .cpu_size     (ex_data_sram_size     ),
    .cpu_addr     (ex_data_sram_addr     ),
    .cpu_wdata    (ex_data_sram_wdata    ),
    .cpu_addr_ok  (ex_data_addr_ok       ),
    .cpu_rdata    (ex_data_sram_rdata    ),
    .cpu_data_ok  (ex_data_ok            ),
    .mem_rd_req   (data_rd_req           ),
    .mem_rd_size  (data_rd_size          ),
    .mem_rd_addr  (data_rd_addr          ),
    .mem_rdata    (data_rd_data          ),
    .mem_rd_ok    (data_rd_ok            ),
    .mem_wr_req   (data_wr_req           ),
    .mem_wr_size  (data_wr_size          ),
    .mem_wr_addr  (data_wr_addr          ),
    .mem_wr_strb  (data_wr_strb          ),
    .mem_wr_data  (data_wr_data          ),
    .mem_wr_ok    (data_wr_ok            ),
    .inst_safe    (dcache_inst_safe      ),
    .perf_hit     (perf_dcache_hit_event ),
    .perf_miss    (perf_dcache_miss_event),
    .perf_wb_stall(perf_wb_stall_event   )
);

// ============================ 指令缓存 ============================
icache u_icache (
    .clk            (clk                                    ),
    .reset          (reset                                  ),
    .flush          (flush                                  ),
    .snoop_valid    (ex_data_sram_en & (|ex_data_sram_we)   ),
    .snoop_addr     (ex_data_sram_addr                      ),
    .req            (ic_req                                 ),
    .addr           (ic_addr                                ),
    .addr_ok        (ic_addr_ok                             ),
    .data_ok        (ic_data_ok                             ),
    .rdata_lo       (ic_rdata_lo                            ),
    .rdata_hi       (ic_rdata_hi                            ),
    .inst_rd_req    (ic_mem_rd_req                          ),
    .inst_rd_addr   (inst_rd_addr                           ),
    .inst_rd_rdy    (inst_rd_rdy & dcache_inst_safe         ),
    .inst_ret_valid (inst_ret_valid                         ),
    .inst_ret_data  (inst_ret_data                          ),
    .inst_ret_last  (inst_ret_last                          ),

    .perf_miss      (perf_icache_miss_event                 )
);

// 写缓冲中的 store 必须先对外可见，随后才能让新的指令 miss 越过它。
assign inst_rd_req = ic_mem_rd_req & dcache_inst_safe;

// ============================ 动态性能计数器 ============================
// 仅用于仿真诊断，不进入 FPGA 网表。
// 官方 Verilator testbench 在 workload 的 0x06/0x07 标记处读取快照并输出差值。
`ifndef SYNTHESIS
reg [63:0] perf_cycle;
reg [63:0] perf_commit0;
reg [63:0] perf_commit1;
reg [63:0] perf_commit2;
reg [63:0] perf_coissue;
reg [63:0] perf_split_total;
reg [63:0] perf_split_raw;
reg [63:0] perf_split_mem;
reg [63:0] perf_split_mul;
reg [63:0] perf_split_branch;
reg [63:0] perf_ooo_issue;
reg [63:0] perf_iq_full;
reg [63:0] perf_icache_miss;
reg [63:0] perf_dcache_hit;
reg [63:0] perf_dcache_miss;
reg [63:0] perf_wb_stall;
reg [63:0] perf_data_wait;
reg [63:0] perf_mul_wait;
reg [63:0] perf_branch_mispred;

always @(posedge clk) begin
    if (reset) begin
        perf_cycle          <= 64'b0;
        perf_commit0        <= 64'b0;
        perf_commit1        <= 64'b0;
        perf_commit2        <= 64'b0;
        perf_coissue        <= 64'b0;
        perf_split_total    <= 64'b0;
        perf_split_raw      <= 64'b0;
        perf_split_mem      <= 64'b0;
        perf_split_mul      <= 64'b0;
        perf_split_branch   <= 64'b0;
        perf_ooo_issue      <= 64'b0;
        perf_iq_full        <= 64'b0;
        perf_icache_miss    <= 64'b0;
        perf_dcache_hit     <= 64'b0;
        perf_dcache_miss    <= 64'b0;
        perf_wb_stall       <= 64'b0;
        perf_data_wait      <= 64'b0;
        perf_mul_wait       <= 64'b0;
        perf_branch_mispred <= 64'b0;
    end else begin
        perf_cycle <= perf_cycle + 64'd1;
        if (!ROB_to_CM_valid)
            perf_commit0 <= perf_commit0 + 64'd1;
        else if (ROB_to_CM_BUS.v1)
            perf_commit2 <= perf_commit2 + 64'd1;
        else
            perf_commit1 <= perf_commit1 + 64'd1;
        if (perf_coissue_event)        perf_coissue        <= perf_coissue + 64'd1;
        if (perf_split_total_event)    perf_split_total    <= perf_split_total + 64'd1;
        if (perf_split_raw_event)      perf_split_raw      <= perf_split_raw + 64'd1;
        if (perf_split_mem_event)      perf_split_mem      <= perf_split_mem + 64'd1;
        if (perf_split_mul_event)      perf_split_mul      <= perf_split_mul + 64'd1;
        if (perf_split_branch_event)   perf_split_branch   <= perf_split_branch + 64'd1;
        if (perf_ooo_issue_event)      perf_ooo_issue      <= perf_ooo_issue + 64'd1;
        if (perf_iq_full_event)        perf_iq_full        <= perf_iq_full + 64'd1;
        if (perf_icache_miss_event)    perf_icache_miss    <= perf_icache_miss + 64'd1;
        if (perf_dcache_hit_event)     perf_dcache_hit     <= perf_dcache_hit + 64'd1;
        if (perf_dcache_miss_event)    perf_dcache_miss    <= perf_dcache_miss + 64'd1;
        if (perf_wb_stall_event)       perf_wb_stall       <= perf_wb_stall + 64'd1;
        if (perf_data_wait_event)      perf_data_wait      <= perf_data_wait + 64'd1;
        if (perf_mul_wait_event)       perf_mul_wait       <= perf_mul_wait + 64'd1;
        if (perf_branch_mispred_event) perf_branch_mispred <= perf_branch_mispred + 64'd1;
    end
end
`endif

endmodule
