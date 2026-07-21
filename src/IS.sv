// ============================================================================
// IS —— 发射（Issue）
//
// 【baseline 直通级】把输入锁存 is_bus_r 原样裹进 IS_to_RF_BUS。实现乱序双发射时
// 在此做唤醒/选择（wakeup-select）并扩展 is_to_rf_bus_t —— 不要删掉本级。
// ============================================================================
import cpu_pkg::*;

module IS (
    input  wire             clk,
    input  wire             reset,
    input  wire             flush,

    input  wire             DP_to_IS_valid,
    input  wire             RF_allow_in,
    output wire             IS_allow_in,
    output wire             IS_to_RF_valid,

    input  dp_to_is_bus_t   DP_to_IS_BUS,
    output is_to_rf_bus_t   IS_to_RF_BUS
);

reg            is_valid;
dp_to_is_bus_t is_bus_r;        // 输入锁存

wire is_ready_go = 1'b1;
assign IS_allow_in    = ~is_valid | (is_ready_go & RF_allow_in);
assign IS_to_RF_valid =  is_valid &  is_ready_go;

always @(posedge clk or posedge reset) begin
    if (reset)            is_valid <= 1'b0;
    else if (flush)       is_valid <= 1'b0;
    else if (IS_allow_in) is_valid <= DP_to_IS_valid;
end

always @(posedge clk or posedge reset) begin
    if (reset)                             is_bus_r <= '0;
    else if (DP_to_IS_valid & IS_allow_in) is_bus_r <= DP_to_IS_BUS;
end

assign IS_to_RF_BUS = '{dp_to_is_bus: is_bus_r};

endmodule
