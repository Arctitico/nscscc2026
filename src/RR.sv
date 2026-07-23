// ============================================================================
// RR —— 寄存器重命名（Register Renaming）
//
// 第一阶段先固化物理寄存器 tag 接口，采用 ARF 同名映射（pN=N）。RR 之后的
// 相关判断、PRF 读写和前递全部使用 6-bit tag。待 ROB/checkpoint 接入后，
// 只需在本级把同名映射替换为 RAT + free-list 分配。
// ============================================================================
import cpu_pkg::*;

module RR (
    input  wire             clk,
    input  wire             reset,
    input  wire             flush,

    input  wire             ID_to_RR_valid,
    input  wire             DP_allow_in,
    output wire             RR_allow_in,
    output wire             RR_to_DP_valid,

    input  id_to_rr_bus_t   ID_to_RR_BUS,
    output rr_to_dp_bus_t   RR_to_DP_BUS
);

reg            rr_valid;
rr_to_dp_bus_t rr_bus_r;

wire rr_ready_go = 1'b1;
assign RR_allow_in    = ~rr_valid | (rr_ready_go & DP_allow_in);
assign RR_to_DP_valid =  rr_valid &  rr_ready_go;

always @(posedge clk) begin
    if (reset)            rr_valid <= 1'b0;
    else if (flush)       rr_valid <= 1'b0;
    else if (RR_allow_in) rr_valid <= ID_to_RR_valid;
end

function automatic preg_t arch_to_preg(input logic [4:0] areg);
    arch_to_preg = preg_t'({1'b0, areg});
endfunction

function automatic rr_slot_t rename_identity(input id_slot_t slot);
    logic [4:0] src2;
    src2 = slot.d_bus.src_reg_is_rd ? slot.d_bus.rd : slot.d_bus.rk;
    rename_identity = '{
        id:       slot,
        psrc1:    arch_to_preg(slot.d_bus.rj),
        psrc2:    arch_to_preg(src2),
        pdst:     arch_to_preg(slot.d_bus.rf_waddr),
        old_pdst: arch_to_preg(slot.d_bus.rf_waddr)
    };
endfunction

always @(posedge clk) begin
    if (ID_to_RR_valid & RR_allow_in) begin
        rr_bus_r <= '{
            s0: rename_identity(ID_to_RR_BUS.s0),
            s1: rename_identity(ID_to_RR_BUS.s1),
            v1: ID_to_RR_BUS.v1
        };
    end
end

assign RR_to_DP_BUS = rr_bus_r;

endmodule
