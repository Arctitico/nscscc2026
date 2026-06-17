// ============================================================================
// Register File read
// ============================================================================
module RF (
    input  wire             clk,
    input  wire             reset,
    input  wire             flush,

    input  wire             IS_to_RF_valid,
    input  wire             EX_allow_in,
    output wire             RF_allow_in,
    output wire             RF_to_EX_valid,

    input  is_to_rf_bus_t   IS_to_RF_BUS,
    output rf_to_ex_bus_t   RF_to_EX_BUS,

    output wire   [ 4:0]    rf_raddr1,
    output wire   [ 4:0]    rf_raddr2,
    input  wire   [31:0]    rf_rdata1,
    input  wire   [31:0]    rf_rdata2,

    // 前递总线
    input  fwd_bus_t        ex_fwd,
    input  fwd_bus_t        wb_fwd,
    input  fwd_bus_t        cm_fwd
);

reg            rf_valid;
is_to_rf_bus_t rf_bus_r; // 输入锁存

// 解开直通封装，取出 {pc, d_bus}
wire [31:0] pc = rf_bus_r.dp_to_is_bus.rr_to_dp_bus.id_to_rr_bus.pc;
d_bus_t     db = rf_bus_r.dp_to_is_bus.rr_to_dp_bus.id_to_rr_bus.d_bus;

assign rf_raddr1 = db.rj;
assign rf_raddr2 = db.src_reg_is_rd ? db.rd : db.rk;

// ---- 前递选择 ----
function automatic [31:0] forward(
    input [ 4:0] addr,
    input [31:0] raw,
    input fwd_bus_t ex, input fwd_bus_t wb, input fwd_bus_t cm
);
    if (ex.valid & ex.rf_we & ~ex.is_ld & (ex.rf_waddr == addr) & (addr != 5'b0))
        forward = ex.rf_wdata;
    else if (wb.valid & wb.rf_we & (wb.rf_waddr == addr) & (addr != 5'b0))
        forward = wb.rf_wdata;
    else if (cm.valid & cm.rf_we & (cm.rf_waddr == addr) & (addr != 5'b0))
        forward = cm.rf_wdata;
    else
        forward = raw;
endfunction

wire [31:0] fwd_rj  = forward(rf_raddr1, rf_rdata1, ex_fwd, wb_fwd, cm_fwd);
wire [31:0] fwd_rkd = forward(rf_raddr2, rf_rdata2, ex_fwd, wb_fwd, cm_fwd);

wire [31:0] alu_src1 = db.src1_is_pc  ? pc      : fwd_rj;
wire [31:0] alu_src2 = db.src2_is_imm ? db.imm  : fwd_rkd;

// ---- load-use 停顿：EX 为加载且写本指令真正用到的源寄存器 ----
wire load_use = ex_fwd.valid & ex_fwd.rf_we & ex_fwd.is_ld & (ex_fwd.rf_waddr != 5'b0) &
                ( (db.need_rj  & (ex_fwd.rf_waddr == rf_raddr1)) |
                  (db.need_rkd & (ex_fwd.rf_waddr == rf_raddr2)) );

wire rf_ready_go = ~load_use;
assign RF_allow_in    = ~rf_valid | (rf_ready_go & EX_allow_in);
assign RF_to_EX_valid =  rf_valid &  rf_ready_go & ~flush; // flush: 分支跳转时 RF 不发出有效信号，阻止错误路径指令进入 EX

always @(posedge clk or posedge reset) begin
    if (reset)            rf_valid <= 1'b0;
    else if (flush)       rf_valid <= 1'b0;
    else if (RF_allow_in) rf_valid <= IS_to_RF_valid;
end

always @(posedge clk or posedge reset) begin
    if (reset)                             rf_bus_r <= '0;
    else if (IS_to_RF_valid & RF_allow_in) rf_bus_r <= IS_to_RF_BUS;
end

assign RF_to_EX_BUS = '{
    pc:            pc,
    imm:           db.imm,
    alu_op:        db.alu_op,
    alu_src1:      alu_src1,
    alu_src2:      alu_src2,
    rkd_value:     fwd_rkd,
    is_branch:     db.is_branch,
    inst_jirl:     db.inst_jirl,
    inst_beq:      db.inst_beq,
    inst_bne:      db.inst_bne,
    is_ld:         db.is_ld,
    is_st:         db.is_st,
    is_st_b:       db.is_st_b,
    ld_width:      db.ld_width,
    ld_ext_signed: db.ld_ext_signed,
    rf_wdata_sel:  db.rf_wdata_sel,
    rf_we:         db.rf_we,
    rf_waddr:      db.rf_waddr
};

endmodule
