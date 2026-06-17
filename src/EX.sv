// ============================================================================
// Execute
// ============================================================================
module EX (
    input  wire             clk,
    input  wire             reset,

    input  wire             RF_to_EX_valid,
    input  wire             WB_allow_in,
    output wire             EX_allow_in,
    output wire             EX_to_WB_valid,

    input  rf_to_ex_bus_t   RF_to_EX_BUS,
    output ex_to_wb_bus_t   EX_to_WB_BUS,

    output wire             br_taken,
    output wire   [31:0]    br_target,

    output fwd_bus_t        ex_fwd,

    output wire             data_sram_en,
    output wire   [ 3:0]    data_sram_we,
    output wire   [31:0]    data_sram_addr,
    output wire   [31:0]    data_sram_wdata,
    input  wire   [31:0]    data_sram_rdata,
    input  wire             data_ok
);

reg            ex_valid;
rf_to_ex_bus_t eb;

wire is_mem      = eb.is_ld | eb.is_st;
wire ex_ready_go = ~(ex_valid & is_mem) | data_ok;
assign EX_allow_in    = ~ex_valid | (ex_ready_go & WB_allow_in);
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

wire        eq         = (eb.alu_src1 == eb.rkd_value);
wire        uncond     = eb.is_branch & ~eb.inst_beq & ~eb.inst_bne;
wire        cond_taken = (eb.inst_beq & eq) | (eb.inst_bne & ~eq);
assign br_taken  = ex_valid & (uncond | cond_taken);
assign br_target = eb.inst_jirl ? (eb.alu_src1 + eb.imm)    // jirl
                                : (eb.pc       + eb.imm);   // b/bl/beq/bne

wire [ 3:0] st_wstrb = eb.is_st_b ? (4'b0001 << alu_result[1:0]) : 4'b1111;
wire [31:0] st_wdata = eb.is_st_b ? {4{eb.rkd_value[7:0]}}       : eb.rkd_value;

assign data_sram_en    = ex_valid & (eb.is_ld | eb.is_st);
assign data_sram_we    = (ex_valid & eb.is_st) ? st_wstrb : 4'b0;
assign data_sram_addr  = alu_result;
assign data_sram_wdata = st_wdata;

assign EX_to_WB_BUS = '{
    pc:            eb.pc,
    alu_result:    alu_result,
    mem_rdata:     data_sram_rdata,
    addr_lo:       alu_result[1:0],
    ld_width:      eb.ld_width,
    ld_ext_signed: eb.ld_ext_signed,
    rf_wdata_sel:  eb.rf_wdata_sel,
    rf_we:         eb.rf_we,
    rf_waddr:      eb.rf_waddr
};

wire [31:0] ex_fwd_data = (eb.rf_wdata_sel == 2'b10) ? (eb.pc + 32'd4) : alu_result;
assign ex_fwd = '{
    valid:    ex_valid,
    rf_we:    eb.rf_we,
    is_ld:    eb.is_ld,
    rf_waddr: eb.rf_waddr,
    rf_wdata: ex_fwd_data
};

endmodule
