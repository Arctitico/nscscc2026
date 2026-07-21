// ============================================================================
// Write Back
// ============================================================================
import cpu_pkg::*;

module WB (
    input  wire             clk,
    input  wire             reset,

    input  wire             EX_to_WB_valid,
    input  wire             CM_allow_in,
    output wire             WB_allow_in,
    output wire             WB_to_CM_valid,

    input  ex_to_wb_bus_t   EX_to_WB_BUS,
    output wb_to_cm_bus_t   WB_to_CM_BUS,

    output fwd_bus_t        wb_fwd
);

reg            wb_valid;
ex_to_wb_bus_t wb_r;

wire wb_ready_go = 1'b1;
assign WB_allow_in    = ~wb_valid | (wb_ready_go & CM_allow_in);
assign WB_to_CM_valid =  wb_valid &  wb_ready_go;

always @(posedge clk or posedge reset) begin
    if (reset)            wb_valid <= 1'b0;
    else if (WB_allow_in) wb_valid <= EX_to_WB_valid;
end

always @(posedge clk or posedge reset) begin
    if (reset)                             wb_r <= '0;
    else if (EX_to_WB_valid & WB_allow_in) wb_r <= EX_to_WB_BUS;
end

wire [ 7:0] byte_sel = (wb_r.addr_lo == 2'b00) ? wb_r.mem_rdata[ 7: 0] :
                       (wb_r.addr_lo == 2'b01) ? wb_r.mem_rdata[15: 8] :
                       (wb_r.addr_lo == 2'b10) ? wb_r.mem_rdata[23:16] :
                                                 wb_r.mem_rdata[31:24];
wire [15:0] half_sel = wb_r.addr_lo[1] ? wb_r.mem_rdata[31:16] : wb_r.mem_rdata[15:0];

logic [31:0] load_data;
always_comb begin
    unique case (wb_r.ld_width)
        4'b1111: load_data = wb_r.mem_rdata;
        4'b0011: load_data = wb_r.ld_ext_signed ? {{16{half_sel[15]}}, half_sel} : {16'b0, half_sel};
        4'b0001: load_data = wb_r.ld_ext_signed ? {{24{byte_sel[7]}},  byte_sel} : {24'b0, byte_sel};
        default: load_data = wb_r.mem_rdata;
    endcase
end

logic [31:0] rf_wdata;
always_comb begin
    unique case (wb_r.rf_wdata_sel)
        2'b01:   rf_wdata = load_data;             // 加载
        2'b10:   rf_wdata = wb_r.pc + 32'd4;       // bl/jirl 链接地址
        default: rf_wdata = wb_r.alu_result;       // ALU
    endcase
end

assign WB_to_CM_BUS = '{
    pc:       wb_r.pc,
    inst:     wb_r.inst,
    rf_wdata: rf_wdata,
    rf_we:    wb_r.rf_we,
    rf_waddr: wb_r.rf_waddr
};

assign wb_fwd = '{
    valid:    wb_valid,
    rf_we:    wb_r.rf_we,
    is_ld:    1'b0,
    rf_waddr: wb_r.rf_waddr,
    rf_wdata: rf_wdata
};

endmodule
