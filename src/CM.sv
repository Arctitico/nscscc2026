// ============================================================================
// Commit：同拍按 slot0、slot1 的程序序提交；同寄存器 WAW 由写口 2 胜出。
// ============================================================================
import cpu_pkg::*;

module CM (
    input  wire             clk,
    input  wire             reset,

    input  wire             EX2_to_CM_valid,
    output wire             CM_allow_in,
    input  ex_to_cm_bus_t   EX2_to_CM_BUS,

    output wire   [ 3:0]    rf_we1,
    output wire   [ 4:0]    rf_waddr1,
    output wire   [31:0]    rf_wdata1,
    output wire   [ 3:0]    rf_we2,
    output wire   [ 4:0]    rf_waddr2,
    output wire   [31:0]    rf_wdata2,

    output fwd_bus_t        cm_fwd0,
    output fwd_bus_t        cm_fwd1,

    output wire   [31:0]    debug_wb_pc,
    output wire   [31:0]    debug_wb_inst,
    output wire   [ 3:0]    debug_wb_rf_we,
    output wire   [ 4:0]    debug_wb_rf_wnum,
    output wire   [31:0]    debug_wb_rf_wdata,
    output wire   [31:0]    debug_wb1_pc,
    output wire   [31:0]    debug_wb1_inst,
    output wire   [ 3:0]    debug_wb1_rf_we,
    output wire   [ 4:0]    debug_wb1_rf_wnum,
    output wire   [31:0]    debug_wb1_rf_wdata
);

reg            cm_valid;
ex_to_cm_bus_t cm_r;

assign CM_allow_in = 1'b1;

always @(posedge clk) begin
    if (reset) cm_valid <= 1'b0;
    else       cm_valid <= EX2_to_CM_valid;
end

always @(posedge clk) begin
    if (EX2_to_CM_valid) cm_r <= EX2_to_CM_BUS;
end

wire do_write0 = cm_valid & cm_r.s0.rf_we;
wire do_write1 = cm_valid & cm_r.v1 & cm_r.s1.rf_we;

assign rf_we1    = {4{do_write0}};
assign rf_waddr1 = cm_r.s0.rf_waddr;
assign rf_wdata1 = cm_r.s0.rf_wdata;
assign rf_we2    = {4{do_write1}};
assign rf_waddr2 = cm_r.s1.rf_waddr;
assign rf_wdata2 = cm_r.s1.rf_wdata;

assign cm_fwd0 = '{valid: cm_valid, rf_we: cm_r.s0.rf_we, is_ld: 1'b0,
                   rf_waddr: cm_r.s0.rf_waddr, rf_wdata: cm_r.s0.rf_wdata};
assign cm_fwd1 = '{valid: cm_valid & cm_r.v1, rf_we: cm_r.s1.rf_we, is_ld: 1'b0,
                   rf_waddr: cm_r.s1.rf_waddr, rf_wdata: cm_r.s1.rf_wdata};

assign debug_wb_pc        = cm_r.s0.pc;
assign debug_wb_inst      = cm_r.s0.inst;
assign debug_wb_rf_we     = {4{do_write0}};
assign debug_wb_rf_wnum   = cm_r.s0.rf_waddr;
assign debug_wb_rf_wdata  = cm_r.s0.rf_wdata;
assign debug_wb1_pc       = cm_r.s1.pc;
assign debug_wb1_inst     = cm_r.s1.inst;
assign debug_wb1_rf_we    = {4{do_write1}};
assign debug_wb1_rf_wnum  = cm_r.s1.rf_waddr;
assign debug_wb1_rf_wdata = cm_r.s1.rf_wdata;

endmodule
