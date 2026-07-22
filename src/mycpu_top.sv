// ============================================================================
// mycpu_top 
//
// 九级流水：IF → ID → RR → DP → IS → RF → EX → WB → CM
//          取指 译码 重命名 分发 发射 读寄存器 执行 写回 提交
//
// 当前为两槽顺序双发射；RR/DP 仍为后续乱序化保留的缓冲级。
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

    output wire        data_sram_en,
    output wire [ 3:0] data_sram_we,
    output wire [ 2:0] data_sram_size,
    output wire [31:0] data_sram_addr,
    output wire [31:0] data_sram_wdata,
    input  wire [31:0] data_sram_rdata,
    input  wire        data_ok,

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

// resetn 由板级 rst_sync 保证异步拉低、同步释放；CPU 内部统一使用
// 高有效同步复位，不再额外打一拍，避免 CPU 与 AXI bridge 复位错位。
wire reset = ~resetn;

wire IF_to_ID_valid;
wire ID_to_RR_valid;
wire RR_to_DP_valid;
wire DP_to_IS_valid;
wire IS_to_RF_valid;
wire RF_to_EX_valid;
wire EX_to_WB_valid;
wire WB_to_CM_valid;

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
wb_to_cm_bus_t WB_to_CM_BUS;

wire [31:0] bp_pc0, bp_pc1;
wire        bp_taken0, bp_taken1;
wire [31:0] bp_target0, bp_target1;

wire        redirect;
wire [31:0] redirect_target;
wire        flush = redirect;

wire        bp_upd_en;
wire [31:0] bp_upd_pc;
wire        bp_upd_taken;
wire        bp_upd_is_cond;
wire [31:0] bp_upd_target;

fwd_bus_t ex_fwd0, ex_fwd1;
fwd_bus_t wb_fwd0, wb_fwd1;
fwd_bus_t cm_fwd0, cm_fwd1;

wire [ 4:0] rf_raddr1, rf_raddr2, rf_raddr3, rf_raddr4;
wire [31:0] rf_rdata1, rf_rdata2, rf_rdata3, rf_rdata4;
wire [ 3:0] rf_we1, rf_we2;
wire [ 4:0] rf_waddr1, rf_waddr2;
wire [31:0] rf_wdata1, rf_wdata2;

wire        ic_req;
wire [31:0] ic_addr;
wire        ic_addr_ok;
wire        ic_data_ok;
wire [31:0] ic_rdata_lo, ic_rdata_hi;

// ============================ 流水级例化 ============================
IF u_IF (
    .clk             (clk             ),
    .reset           (reset           ),
    .IF_to_ID_valid  (IF_to_ID_valid  ),
    .ID_allow_in     (ID_allow_in     ),
    .IF_to_ID_BUS    (IF_to_ID_BUS    ),
    .bp_pc0          (bp_pc0          ),
    .bp_pc1          (bp_pc1          ),
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
    .RR_to_DP_BUS  (RR_to_DP_BUS  )
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
    .clk           (clk           ),
    .reset         (reset         ),
    .flush         (flush         ),
    .DP_to_IS_valid(DP_to_IS_valid),
    .RF_allow_in   (RF_allow_in   ),
    .IS_allow_in   (IS_allow_in   ),
    .IS_to_RF_valid(IS_to_RF_valid),
    .DP_to_IS_BUS  (DP_to_IS_BUS  ),
    .IS_to_RF_BUS  (IS_to_RF_BUS  )
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
    .clk            (clk            ),
    .reset          (reset          ),
    .RF_to_EX_valid (RF_to_EX_valid ),
    .WB_allow_in    (WB_allow_in    ),
    .EX_allow_in    (EX_allow_in    ),
    .EX_to_WB_valid (EX_to_WB_valid ),
    .RF_to_EX_BUS   (RF_to_EX_BUS   ),
    .EX_to_WB_BUS   (EX_to_WB_BUS   ),
    .redirect       (redirect       ),
    .redirect_target(redirect_target),
    .bp_upd_en      (bp_upd_en      ),
    .bp_upd_pc      (bp_upd_pc      ),
    .bp_upd_taken   (bp_upd_taken   ),
    .bp_upd_is_cond (bp_upd_is_cond ),
    .bp_upd_target  (bp_upd_target  ),
    .ex_fwd0        (ex_fwd0        ),
    .ex_fwd1        (ex_fwd1        ),
    .data_sram_en   (data_sram_en   ),
    .data_sram_we   (data_sram_we   ),
    .data_sram_size (data_sram_size ),
    .data_sram_addr (data_sram_addr ),
    .data_sram_wdata(data_sram_wdata),
    .data_sram_rdata(data_sram_rdata),
    .data_ok        (data_ok        )
);

WB u_WB (
    .clk           (clk           ),
    .reset         (reset         ),
    .EX_to_WB_valid(EX_to_WB_valid),
    .CM_allow_in   (CM_allow_in   ),
    .WB_allow_in   (WB_allow_in   ),
    .WB_to_CM_valid(WB_to_CM_valid),
    .EX_to_WB_BUS  (EX_to_WB_BUS  ),
    .WB_to_CM_BUS  (WB_to_CM_BUS  ),
    .wb_fwd0       (wb_fwd0       ),
    .wb_fwd1       (wb_fwd1       )
);

CM u_CM (
    .clk              (clk              ),
    .reset            (reset            ),
    .WB_to_CM_valid   (WB_to_CM_valid   ),
    .CM_allow_in      (CM_allow_in      ),
    .WB_to_CM_BUS     (WB_to_CM_BUS     ),
    .rf_we1           (rf_we1           ),
    .rf_waddr1        (rf_waddr1        ),
    .rf_wdata1        (rf_wdata1        ),
    .rf_we2            (rf_we2            ),
    .rf_waddr2         (rf_waddr2         ),
    .rf_wdata2         (rf_wdata2         ),
    .cm_fwd0           (cm_fwd0           ),
    .cm_fwd1           (cm_fwd1           ),
    .debug_wb_pc      (debug_wb_pc      ),
    .debug_wb_inst    (debug_wb_inst    ),
    .debug_wb_rf_we   (debug_wb_rf_we   ),
    .debug_wb_rf_wnum (debug_wb_rf_wnum ),
    .debug_wb_rf_wdata(debug_wb_rf_wdata),
    .debug_wb1_pc      (debug_wb1_pc      ),
    .debug_wb1_inst    (debug_wb1_inst    ),
    .debug_wb1_rf_we   (debug_wb1_rf_we   ),
    .debug_wb1_rf_wnum (debug_wb1_rf_wnum ),
    .debug_wb1_rf_wdata(debug_wb1_rf_wdata)
);

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
    .pred_pc1     (bp_pc1        ),
    .pred_taken1  (bp_taken1     ),
    .pred_target1 (bp_target1    ),
    .upd_en       (bp_upd_en     ),
    .upd_pc       (bp_upd_pc     ),
    .upd_taken    (bp_upd_taken  ),
    .upd_is_cond  (bp_upd_is_cond),
    .upd_target   (bp_upd_target )
);

// ============================ 指令缓存 ============================
icache u_icache (
    .clk            (clk            ),
    .reset          (reset          ),
    .flush          (flush          ),
    .snoop_valid    (data_sram_en & (|data_sram_we)),
    .snoop_addr     (data_sram_addr ),
    .req            (ic_req         ),
    .addr           (ic_addr        ),
    .addr_ok        (ic_addr_ok     ),
    .data_ok        (ic_data_ok     ),
    .rdata_lo       (ic_rdata_lo    ),
    .rdata_hi       (ic_rdata_hi    ),
    .inst_rd_req    (inst_rd_req    ),
    .inst_rd_addr   (inst_rd_addr   ),
    .inst_rd_rdy    (inst_rd_rdy    ),
    .inst_ret_valid (inst_ret_valid ),
    .inst_ret_data  (inst_ret_data  ),
    .inst_ret_last  (inst_ret_last  )
);

endmodule
