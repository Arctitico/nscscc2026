// ============================================================================
// DP —— 指令粒度分发 FIFO
//
// ID 每拍原子送入一条或两条已译码指令，IS 每拍从队头取一条或两条。FIFO
// 不保留原取指 bundle 边界，因此 IS 拆发一条后，剩余指令可以与下一条重新配对。
//
// 满/空间不足时即使同拍出队也保守地不接收新项，保持 RF 到 ID 的 ready 路径
// 非穿透。默认六项；仿真可用 -DDP_FIFO_DEPTH=4 做缩容对照。
// ============================================================================
import cpu_pkg::*;

`ifndef DP_FIFO_DEPTH
`define DP_FIFO_DEPTH 6
`endif

module DP (
    input  wire             clk,
    input  wire             reset,
    input  wire             flush,

    input  wire             ID_to_DP_valid,
    input  wire             IS_allow_in,
    input  wire             IS_take_two,
    output wire             DP_allow_in,
    output wire             DP_to_IS_valid,

    input  id_to_dp_bus_t   ID_to_DP_BUS,
    output dp_to_is_bus_t   DP_to_IS_BUS
);

localparam integer DEPTH   = `DP_FIFO_DEPTH;
localparam integer PTR_W   = (DEPTH <= 2) ? 1 : $clog2(DEPTH);
localparam integer COUNT_W = $clog2(DEPTH + 1);

id_slot_t fifo [0:DEPTH-1];
reg [PTR_W-1:0] rd_ptr;
reg [PTR_W-1:0] wr_ptr;
reg [COUNT_W-1:0] count;

function automatic [PTR_W-1:0] ptr_add(
    input [PTR_W-1:0] ptr,
    input [1:0]       amount
);
    integer sum;
    begin
        sum = ptr + amount;
        if (sum >= DEPTH)
            sum = sum - DEPTH;
        ptr_add = sum[PTR_W-1:0];
    end
endfunction

wire input_two = ID_to_DP_BUS.v1;
wire room_for_input = input_two ? (count <= DEPTH - 2)
                                : (count <= DEPTH - 1);
assign DP_allow_in    = ~ID_to_DP_valid | room_for_input;
assign DP_to_IS_valid = (count != 0);

wire push = ID_to_DP_valid & DP_allow_in;
wire pop  = DP_to_IS_valid & IS_allow_in;
wire [1:0] push_count = push ? (input_two ? 2'd2 : 2'd1) : 2'd0;
wire [1:0] pop_count  = pop  ? (IS_take_two ? 2'd2 : 2'd1) : 2'd0;

always @(posedge clk) begin
    if (reset | flush) begin
        rd_ptr <= '0;
        wr_ptr <= '0;
        count  <= '0;
    end else begin
        count <= count + push_count - pop_count;
        if (push) wr_ptr <= ptr_add(wr_ptr, push_count);
        if (pop)  rd_ptr <= ptr_add(rd_ptr, pop_count);
    end
end

always @(posedge clk) begin
    if (push) begin
        fifo[wr_ptr] <= ID_to_DP_BUS.s0;
        if (input_two)
            fifo[ptr_add(wr_ptr, 2'd1)] <= ID_to_DP_BUS.s1;
    end
end

id_to_dp_bus_t head_bus;
always_comb begin
    head_bus.s0 = fifo[rd_ptr];
    head_bus.s1 = fifo[ptr_add(rd_ptr, 2'd1)];
    head_bus.v1 = (count >= 2);
end

assign DP_to_IS_BUS = '{id_to_dp_bus: head_bus};

endmodule
