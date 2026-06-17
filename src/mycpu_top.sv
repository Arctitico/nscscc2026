// ============================================================================
// mycpu_top 
//
// 九级流水：IF → ID → RR → DP → IS → RF → EX → WB → CM
//          取指 译码 重命名 分发 发射 读寄存器 执行 写回 提交
//
// RR/DP/IS 当前为直通缓冲级，为乱序双发射保留（见各模块/ cpu_pkg.sv 注释）
// ============================================================================
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
    output wire [31:0] data_sram_addr,
    output wire [31:0] data_sram_wdata,
    input  wire [31:0] data_sram_rdata,
    input  wire        data_ok,

    output wire [31:0] debug_wb_pc,
    output wire [ 3:0] debug_wb_rf_we,
    output wire [ 4:0] debug_wb_rf_wnum,
    output wire [31:0] debug_wb_rf_wdata
);

reg reset;
always @(posedge clk) reset <= ~resetn;

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

wire        bp_pred_taken;
wire [31:0] bp_pred_target;
wire [31:0] bp_pc;

wire        redirect;
wire [31:0] redirect_target;
wire        flush = redirect;

wire        bp_upd_en;
wire [31:0] bp_upd_pc;
wire        bp_upd_taken;
wire        bp_upd_is_cond;
wire [31:0] bp_upd_target;

fwd_bus_t ex_fwd;
fwd_bus_t wb_fwd;
fwd_bus_t cm_fwd;

wire [ 4:0] rf_raddr1, rf_raddr2;
wire [31:0] rf_rdata1, rf_rdata2;
wire [31:0] rf_rdata3, rf_rdata4;   
wire [ 3:0] rf_we1;
wire [ 4:0] rf_waddr1;
wire [31:0] rf_wdata1;

wire        ic_req;
wire [31:0] ic_addr;
wire        ic_addr_ok;
wire        ic_data_ok;
wire [31:0] ic_rdata;

// ============================ 流水级例化 ============================
IF u_IF (
    .clk             (clk             ),
    .reset           (reset           ),
    .IF_to_ID_valid  (IF_to_ID_valid  ),
    .ID_allow_in     (ID_allow_in     ),
    .IF_to_ID_BUS    (IF_to_ID_BUS    ),
    .bp_pc           (bp_pc           ),
    .bp_taken        (bp_pred_taken   ),
    .bp_target       (bp_pred_target  ),
    .redirect        (redirect        ),
    .redirect_target (redirect_target ),
    .ic_req          (ic_req          ),
    .ic_addr         (ic_addr         ),
    .ic_addr_ok      (ic_addr_ok      ),
    .ic_data_ok      (ic_data_ok      ),
    .ic_rdata        (ic_rdata        )
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
    .rf_rdata1     (rf_rdata1     ),
    .rf_rdata2     (rf_rdata2     ),
    .ex_fwd        (ex_fwd        ),
    .wb_fwd        (wb_fwd        ),
    .cm_fwd        (cm_fwd        )
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
    .ex_fwd         (ex_fwd         ),
    .data_sram_en   (data_sram_en   ),
    .data_sram_we   (data_sram_we   ),
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
    .wb_fwd        (wb_fwd        )
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
    .cm_fwd           (cm_fwd           ),
    .debug_wb_pc      (debug_wb_pc      ),
    .debug_wb_rf_we   (debug_wb_rf_we   ),
    .debug_wb_rf_wnum (debug_wb_rf_wnum ),
    .debug_wb_rf_wdata(debug_wb_rf_wdata)
);

// ============================ 寄存器堆 ============================
regfile u_regfile (
    .clk      (clk      ),
    .rf_raddr1(rf_raddr1), .rf_rdata1(rf_rdata1),
    .rf_raddr2(rf_raddr2), .rf_rdata2(rf_rdata2),
    .rf_raddr3(5'b0     ), .rf_rdata3(rf_rdata3),
    .rf_raddr4(5'b0     ), .rf_rdata4(rf_rdata4),
    .rf_we1   (rf_we1   ), .rf_waddr1(rf_waddr1), .rf_wdata1(rf_wdata1),
    .rf_we2   (4'b0     ), .rf_waddr2(5'b0     ), .rf_wdata2(32'b0    )
);

// ============================ 分支预测 ============================
bpu u_bpu (
    .clk          (clk           ),
    .reset        (reset         ),
    .pred_pc      (bp_pc         ),
    .pred_taken   (bp_pred_taken ),
    .pred_target  (bp_pred_target),
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
    .req            (ic_req         ),
    .addr           (ic_addr        ),
    .addr_ok        (ic_addr_ok     ),
    .data_ok        (ic_data_ok     ),
    .rdata          (ic_rdata       ),
    .inst_rd_req    (inst_rd_req    ),
    .inst_rd_addr   (inst_rd_addr   ),
    .inst_rd_rdy    (inst_rd_rdy    ),
    .inst_ret_valid (inst_ret_valid ),
    .inst_ret_data  (inst_ret_data  ),
    .inst_ret_last  (inst_ret_last  )
);

endmodule
