// ============================================================================
// RR —— 寄存器重命名（Register Renaming）
//
// 【baseline 直通级】输入锁存约定。顺序单发射阶段仅作流水缓冲：
// 把输入锁存 rr_bus_r 原样裹进 RR_to_DP_BUS 组合输出。实现乱序双发射时在此做
// 寄存器重命名并扩展 rr_to_dp_bus_t 携带物理寄存器 tag —— 不要删掉本级。
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
id_to_rr_bus_t rr_bus_r;        // 输入锁存

wire rr_ready_go = 1'b1;
assign RR_allow_in    = ~rr_valid | (rr_ready_go & DP_allow_in);
assign RR_to_DP_valid =  rr_valid &  rr_ready_go;

always @(posedge clk) begin
    if (reset)            rr_valid <= 1'b0;
    else if (flush)       rr_valid <= 1'b0;
    else if (RR_allow_in) rr_valid <= ID_to_RR_valid;
end

always @(posedge clk) begin
    if (ID_to_RR_valid & RR_allow_in) rr_bus_r <= ID_to_RR_BUS;
end

assign RR_to_DP_BUS = '{id_to_rr_bus: rr_bus_r};

endmodule
