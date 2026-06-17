// ============================================================================
// commit
// ============================================================================
module CM (
    input  wire             clk,
    input  wire             reset,

    input  wire             WB_to_CM_valid,
    output wire             CM_allow_in,

    input  wb_to_cm_bus_t   WB_to_CM_BUS,

    output wire   [ 3:0]    rf_we1,
    output wire   [ 4:0]    rf_waddr1,
    output wire   [31:0]    rf_wdata1,

    output fwd_bus_t        cm_fwd,

    output wire   [31:0]    debug_wb_pc,
    output wire   [ 3:0]    debug_wb_rf_we,
    output wire   [ 4:0]    debug_wb_rf_wnum,
    output wire   [31:0]    debug_wb_rf_wdata
);

reg            cm_valid;
wb_to_cm_bus_t cm_r;

wire cm_ready_go = 1'b1;
assign CM_allow_in = ~cm_valid | cm_ready_go;   // 恒 1：每拍可提交

always @(posedge clk or posedge reset) begin
    if (reset)            cm_valid <= 1'b0;
    else if (CM_allow_in) cm_valid <= WB_to_CM_valid;
end

always @(posedge clk or posedge reset) begin
    if (reset)                             cm_r <= '0;
    else if (WB_to_CM_valid & CM_allow_in) cm_r <= WB_to_CM_BUS;
end

wire do_write = cm_valid & cm_r.rf_we;

assign rf_we1    = {4{do_write}};
assign rf_waddr1 = cm_r.rf_waddr;
assign rf_wdata1 = cm_r.rf_wdata;

assign cm_fwd = '{
    valid:    cm_valid,
    rf_we:    cm_r.rf_we,
    is_ld:    1'b0,
    rf_waddr: cm_r.rf_waddr,
    rf_wdata: cm_r.rf_wdata
};

assign debug_wb_pc       = cm_r.pc;
assign debug_wb_rf_we    = {4{do_write}};
assign debug_wb_rf_wnum  = cm_r.rf_waddr;
assign debug_wb_rf_wdata = cm_r.rf_wdata;

endmodule
