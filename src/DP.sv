// ============================================================================
// DP —— 分发（Dispatch）
//
// 【baseline 直通级】把输入锁存 dp_bus_r 原样裹进 DP_to_IS_BUS。实现乱序双发射时
// 在此把指令分发到发射队列 / 保留站并扩展 dp_to_is_bus_t —— 不要删掉本级。
// ============================================================================
import cpu_pkg::*;

module DP (
    input  wire             clk,
    input  wire             reset,
    input  wire             flush,

    input  wire             RR_to_DP_valid,
    input  wire             IS_allow_in,
    output wire             DP_allow_in,
    output wire             DP_to_IS_valid,

    input  rr_to_dp_bus_t   RR_to_DP_BUS,
    output dp_to_is_bus_t   DP_to_IS_BUS
);

reg            dp_valid;
rr_to_dp_bus_t dp_bus_r;        // 输入锁存

wire dp_ready_go = 1'b1;
assign DP_allow_in    = ~dp_valid | (dp_ready_go & IS_allow_in);
assign DP_to_IS_valid =  dp_valid &  dp_ready_go;

always @(posedge clk or posedge reset) begin
    if (reset)            dp_valid <= 1'b0;
    else if (flush)       dp_valid <= 1'b0;
    else if (DP_allow_in) dp_valid <= RR_to_DP_valid;
end

always @(posedge clk or posedge reset) begin
    if (reset)                             dp_bus_r <= '0;
    else if (RR_to_DP_valid & DP_allow_in) dp_bus_r <= RR_to_DP_BUS;
end

assign DP_to_IS_BUS = '{rr_to_dp_bus: dp_bus_r};

endmodule
