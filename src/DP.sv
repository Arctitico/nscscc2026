// ============================================================================
// DP —— 分发（Dispatch）
//
// 当前实现为三项非穿透 dispatch FIFO。它融合了原先仅作直通缓冲的 RR
// 寄存级及两项 DP FIFO：不减少长停顿时可吸收的 bundle 数量，同时让 ID
// 译码结果少经过一拍才到达 IS。本顺序分支不再保留 rename 占位级。
//
// FIFO 满且同拍出队时保守地不接收新项。下游从长停顿恢复的第一拍会产生一个
// 空位，之后仍可保持每拍一组的吞吐；这个恢复气泡换取 ready 路径完全非穿透。
// ============================================================================
import cpu_pkg::*;

module DP (
    input  wire             clk,
    input  wire             reset,
    input  wire             flush,

    input  wire             ID_to_DP_valid,
    input  wire             IS_allow_in,
    output wire             DP_allow_in,
    output wire             DP_to_IS_valid,

    input  id_to_dp_bus_t   ID_to_DP_BUS,
    output dp_to_is_bus_t   DP_to_IS_BUS
);

id_to_dp_bus_t fifo [0:2];
reg [1:0]      rd_ptr;
reg [1:0]      wr_ptr;
reg [1:0]      count;

assign DP_allow_in    = (count != 2'd3);
assign DP_to_IS_valid = (count != 2'd0);

wire push = ID_to_DP_valid & DP_allow_in;
wire pop  = DP_to_IS_valid & IS_allow_in;

always @(posedge clk) begin
    if (reset | flush) begin
        rd_ptr <= 2'd0;
        wr_ptr <= 2'd0;
        count  <= 2'd0;
    end else begin
        case ({push, pop})
        2'b10: count <= count + 2'd1;
        2'b01: count <= count - 2'd1;
        default: count <= count;
        endcase
        if (push) wr_ptr <= (wr_ptr == 2'd2) ? 2'd0 : wr_ptr + 2'd1;
        if (pop)  rd_ptr <= (rd_ptr == 2'd2) ? 2'd0 : rd_ptr + 2'd1;
    end
end

always @(posedge clk) begin
    if (push) fifo[wr_ptr] <= ID_to_DP_BUS;
end

assign DP_to_IS_BUS = '{id_to_dp_bus: fifo[rd_ptr]};

endmodule
