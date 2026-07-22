// ============================================================================
// Execute
// ============================================================================
import cpu_pkg::*;

module EX (
    input  wire             clk,
    input  wire             reset,

    input  wire             RF_to_EX_valid,
    input  wire             WB_allow_in,
    output wire             EX_allow_in,
    output wire             EX_to_WB_valid,

    input  rf_to_ex_bus_t   RF_to_EX_BUS,
    output ex_to_wb_bus_t   EX_to_WB_BUS,

    // 预测错误时，重定向
    output wire             redirect,
    output wire   [31:0]    redirect_target,

    // 分支预测器更新
    output wire             bp_upd_en,
    output wire   [31:0]    bp_upd_pc,
    output wire             bp_upd_taken,
    output wire             bp_upd_is_cond,
    output wire   [31:0]    bp_upd_target,

    output fwd_bus_t        ex_fwd,

    output wire             data_sram_en,
    output wire   [ 3:0]    data_sram_we,
    output wire   [ 2:0]    data_sram_size,
    output wire   [31:0]    data_sram_addr,
    output wire   [31:0]    data_sram_wdata,
    input  wire   [31:0]    data_sram_rdata,
    input  wire             data_ok
);

reg            ex_valid;
rf_to_ex_bus_t eb;

wire is_mem = eb.is_ld | eb.is_st;

wire        mul_in_valid;
wire        mul_in_ready;
wire        mul_out_valid;
wire        mul_out_ready;
wire [31:0] mul_low;
wire [31:0] mul_high_unused;

wire ex_ready_go = eb.is_mul ? mul_out_valid :
                   is_mem    ? data_ok       : 1'b1;
wire ex_slot_allow = ~ex_valid | (ex_ready_go & WB_allow_in);

// 新乘法指令只有在乘法流水线能接收时才能进入 EX；其它指令不受影响。
assign EX_allow_in    = ex_slot_allow &
                        (~RF_to_EX_valid | ~RF_to_EX_BUS.is_mul | mul_in_ready);
assign EX_to_WB_valid =  ex_valid &  ex_ready_go;

always @(posedge clk or posedge reset) begin
    if (reset)            ex_valid <= 1'b0;
    else if (EX_allow_in) ex_valid <= RF_to_EX_valid;
end

always @(posedge clk or posedge reset) begin
    if (reset)                             eb <= '0;
    else if (RF_to_EX_valid & EX_allow_in) eb <= RF_to_EX_BUS;
end

wire [31:0] alu_result;
alu u_alu(
    .alu_src1   (eb.alu_src1),
    .alu_src2   (eb.alu_src2),
    .alu_op     (eb.alu_op  ),
    .alu_result (alu_result )
);

assign mul_in_valid  = RF_to_EX_valid & EX_allow_in & RF_to_EX_BUS.is_mul;
assign mul_out_ready = ex_valid & eb.is_mul & WB_allow_in;

mul u_mul (
    .clk        (clk                         ),
    .reset      (reset                       ),
    .in_valid   (mul_in_valid                ),
    .in_ready   (mul_in_ready                ),
    .a_in       (RF_to_EX_BUS.alu_src1       ),
    .b_in       (RF_to_EX_BUS.alu_src2       ),
    .is_signed  (1'b1                        ),
    .out_valid  (mul_out_valid               ),
    .out_ready  (mul_out_ready               ),
    .c_low      (mul_low                     ),
    .c_high     (mul_high_unused             )
);

// 无 Cache baseline 只需要让默认 supervisor 识别“没有 I/D Cache”。
// 当前软件只读取 0x10；其它未实现配置字按架构约定返回 0。
logic [31:0] cpucfg_result;
always_comb begin
    unique case (eb.alu_src1)
        32'h0000_0010: cpucfg_result = 32'h0000_0000;
        default:       cpucfg_result = 32'h0000_0000;
    endcase
end

wire [31:0] execute_result = eb.is_cpucfg ? cpucfg_result :
                             eb.is_mul    ? mul_low       : alu_result;

wire        eq         = (eb.alu_src1 == eb.rkd_value);
wire        uncond     = eb.is_branch & ~eb.inst_beq & ~eb.inst_bne;
wire        cond_taken = (eb.inst_beq & eq) | (eb.inst_bne & ~eq);
wire        br_taken   = ex_valid & (uncond | cond_taken);
wire [31:0] br_target  = eb.inst_jirl ? (eb.alu_src1 + eb.imm)    // jirl
                                      : (eb.pc       + eb.imm);   // b/bl/beq/bne

// 对于分支指令，预测错误时，重定向
// 分为 direction 错误和 target 错误两种情况
wire dir_wrong = eb.bp_taken ^ br_taken;
wire tgt_wrong = br_taken & eb.bp_taken & (br_target != eb.bp_target);
assign redirect        = ex_valid & eb.is_branch & (dir_wrong | tgt_wrong);
assign redirect_target = br_taken ? br_target : (eb.pc + 32'd4);

// 分支预测器更新
assign bp_upd_en      = EX_to_WB_valid & WB_allow_in & eb.is_branch;
assign bp_upd_pc      = eb.pc;
assign bp_upd_taken   = br_taken;
assign bp_upd_is_cond = eb.inst_beq | eb.inst_bne;
assign bp_upd_target  = br_target;

wire [ 3:0] st_wstrb = eb.is_st_b ? (4'b0001 << alu_result[1:0]) : 4'b1111;
wire [31:0] st_wdata = eb.is_st_b ? {4{eb.rkd_value[7:0]}}       : eb.rkd_value;

assign data_sram_en    = ex_valid & (eb.is_ld | eb.is_st);
assign data_sram_we    = (ex_valid & eb.is_st) ? st_wstrb : 4'b0;
assign data_sram_size  = (eb.is_st_b | (eb.is_ld & (eb.ld_width == 4'b0001))) ? 3'b000 : 3'b010;
assign data_sram_addr  = alu_result;
assign data_sram_wdata = st_wdata;

assign EX_to_WB_BUS = '{
    pc:            eb.pc,
    inst:          eb.inst,
    alu_result:    execute_result,
    mem_rdata:     data_sram_rdata,
    addr_lo:       alu_result[1:0],
    ld_width:      eb.ld_width,
    ld_ext_signed: eb.ld_ext_signed,
    rf_wdata_sel:  eb.rf_wdata_sel,
    rf_we:         eb.rf_we,
    rf_waddr:      eb.rf_waddr
};

wire [31:0] ex_fwd_data = (eb.rf_wdata_sel == 2'b10) ? (eb.pc + 32'd4) : execute_result;
assign ex_fwd = '{
    valid:    ex_valid & (~eb.is_mul | mul_out_valid),
    rf_we:    eb.rf_we,
    is_ld:    eb.is_ld,
    rf_waddr: eb.rf_waddr,
    rf_wdata: ex_fwd_data
};

endmodule
