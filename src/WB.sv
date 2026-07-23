// ============================================================================
// Write Back：EX2 已经汇合 ALU、乘法和访存结果，本级只提供一个
// 非穿透弹性寄存器，并向 RF 广播稳定的最终写回数据。
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

    output fwd_bus_t        wb_fwd0,
    output fwd_bus_t        wb_fwd1
);

reg            wb_valid;
ex_to_wb_bus_t wb_r;

assign WB_allow_in    = ~wb_valid | CM_allow_in;
assign WB_to_CM_valid =  wb_valid;

always @(posedge clk) begin
    if (reset)            wb_valid <= 1'b0;
    else if (WB_allow_in) wb_valid <= EX_to_WB_valid;
end

always @(posedge clk) begin
    if (EX_to_WB_valid & WB_allow_in) wb_r <= EX_to_WB_BUS;
end

assign WB_to_CM_BUS = '{
    s0: '{pc: wb_r.s0.pc, inst: wb_r.s0.inst, rf_wdata: wb_r.s0.rf_wdata,
          rf_we: wb_r.s0.rf_we, rf_waddr: wb_r.s0.rf_waddr},
    s1: '{pc: wb_r.s1.pc, inst: wb_r.s1.inst, rf_wdata: wb_r.s1.rf_wdata,
          rf_we: wb_r.s1.rf_we, rf_waddr: wb_r.s1.rf_waddr},
    v1: wb_r.v1
};

assign wb_fwd0 = '{valid: wb_valid, rf_we: wb_r.s0.rf_we, is_ld: 1'b0,
                   rf_waddr: wb_r.s0.rf_waddr, rf_wdata: wb_r.s0.rf_wdata};
assign wb_fwd1 = '{valid: wb_valid & wb_r.v1, rf_we: wb_r.s1.rf_we,
                   is_ld: 1'b0,
                   rf_waddr: wb_r.s1.rf_waddr, rf_wdata: wb_r.s1.rf_wdata};

endmodule
