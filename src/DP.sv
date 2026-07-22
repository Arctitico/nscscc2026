// ============================================================================
// DP —— 分发（Dispatch）
//
// 当前实现为两项非穿透 dispatch FIFO。输入 ready 只由已寄存的占用数决定，
// 不再把 IS/RF/EX/WB 的背压组合传播回 RR/ID；这既切断全流水 allow-in
// 关键路径，也为后续 rename -> dispatch -> issue queue 保留明确的解耦边界。
//
// FIFO 满且同拍出队时保守地不接收新项。下游从长停顿恢复的第一拍会产生一个
// 空位，之后仍可保持每拍一组的吞吐；这个恢复气泡换取 ready 路径完全非穿透。
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

rr_to_dp_bus_t fifo [0:1];
reg            rd_ptr;
reg            wr_ptr;
reg [1:0]      count;

assign DP_allow_in    = (count != 2'd2);
assign DP_to_IS_valid = (count != 2'd0);

wire push = RR_to_DP_valid & DP_allow_in;
wire pop  = DP_to_IS_valid & IS_allow_in;

always @(posedge clk) begin
    if (reset | flush) begin
        rd_ptr <= 1'b0;
        wr_ptr <= 1'b0;
        count  <= 2'd0;
    end else begin
        case ({push, pop})
        2'b10: count <= count + 2'd1;
        2'b01: count <= count - 2'd1;
        default: count <= count;
        endcase
        if (push) wr_ptr <= ~wr_ptr;
        if (pop)  rd_ptr <= ~rd_ptr;
    end
end

always @(posedge clk) begin
    if (push) fifo[wr_ptr] <= RR_to_DP_BUS;
end

assign DP_to_IS_BUS = '{rr_to_dp_bus: fifo[rd_ptr]};

endmodule
