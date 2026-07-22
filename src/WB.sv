// ============================================================================
// Memory response / Write Back：访存指令在此等待 data_ok，
// 两槽独立完成 load 对齐/扩展和写回数据选择。
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

    input  wire   [31:0]    data_sram_rdata,
    input  wire             data_ok,

    output fwd_bus_t        wb_fwd0,
    output fwd_bus_t        wb_fwd1,
    output wire             perf_data_wait
);

reg            wb_valid;
ex_to_wb_bus_t wb_r;

wire wb_mem = wb_r.s0.is_mem | (wb_r.v1 & wb_r.s1.is_mem);
wire wb_ready_go = ~wb_mem | data_ok;
assign WB_allow_in    = ~wb_valid | (wb_ready_go & CM_allow_in);
assign WB_to_CM_valid =  wb_valid &  wb_ready_go;
assign perf_data_wait = wb_valid & wb_mem & ~data_ok;

always @(posedge clk) begin
    if (reset)            wb_valid <= 1'b0;
    else if (WB_allow_in) wb_valid <= EX_to_WB_valid;
end

always @(posedge clk) begin
    if (EX_to_WB_valid & WB_allow_in) wb_r <= EX_to_WB_BUS;
end

function automatic [31:0] load_data(input ex_wb_slot_t w,
                                    input [31:0] mem_rdata);
    logic [7:0]  byte_sel;
    logic [15:0] half_sel;
    byte_sel = (w.addr_lo == 2'b00) ? mem_rdata[ 7: 0] :
               (w.addr_lo == 2'b01) ? mem_rdata[15: 8] :
               (w.addr_lo == 2'b10) ? mem_rdata[23:16] : mem_rdata[31:24];
    half_sel = w.addr_lo[1] ? mem_rdata[31:16] : mem_rdata[15:0];
    case (w.ld_width)
        4'b1111: load_data = mem_rdata;
        4'b0011: load_data = w.ld_ext_signed ? {{16{half_sel[15]}}, half_sel}
                                              : {16'b0, half_sel};
        4'b0001: load_data = w.ld_ext_signed ? {{24{byte_sel[7]}}, byte_sel}
                                              : {24'b0, byte_sel};
        default: load_data = mem_rdata;
    endcase
endfunction

function automatic [31:0] write_data(input ex_wb_slot_t w,
                                     input [31:0] mem_rdata);
    case (w.rf_wdata_sel)
        2'b01:   write_data = load_data(w, mem_rdata);
        2'b10:   write_data = w.pc + 32'd4;
        default: write_data = w.alu_result;
    endcase
endfunction

wire [31:0] rf_wdata0 = write_data(wb_r.s0, data_sram_rdata);
wire [31:0] rf_wdata1 = write_data(wb_r.s1, data_sram_rdata);

assign WB_to_CM_BUS = '{
    s0: '{pc: wb_r.s0.pc, inst: wb_r.s0.inst, rf_wdata: rf_wdata0,
          rf_we: wb_r.s0.rf_we, rf_waddr: wb_r.s0.rf_waddr},
    s1: '{pc: wb_r.s1.pc, inst: wb_r.s1.inst, rf_wdata: rf_wdata1,
          rf_we: wb_r.s1.rf_we, rf_waddr: wb_r.s1.rf_waddr},
    v1: wb_r.v1
};

assign wb_fwd0 = '{valid: wb_valid, rf_we: wb_r.s0.rf_we,
                   // 命中数据在本拍末写入 CM；不把 tag-compare/data_ok
                   // 组合穿过 WB/RF 直接送到下一条指令，下一拍由 CM 前递。
                   is_ld: wb_r.s0.is_mem & (wb_r.s0.rf_wdata_sel == 2'b01),
                   rf_waddr: wb_r.s0.rf_waddr, rf_wdata: rf_wdata0};
assign wb_fwd1 = '{valid: wb_valid & wb_r.v1, rf_we: wb_r.s1.rf_we,
                   is_ld: wb_r.s1.is_mem & (wb_r.s1.rf_wdata_sel == 2'b01),
                   rf_waddr: wb_r.s1.rf_waddr, rf_wdata: rf_wdata1};

endmodule
