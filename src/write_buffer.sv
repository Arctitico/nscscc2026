// ============================================================================
// 四项 FIFO 写缓冲：缓存普通 SRAM store，直到外部写响应返回。
//
// enqueue 与队首完成可同拍发生。对外只暴露 FIFO 队首，载荷在 mem_done
// 前保持稳定。满缓冲时读写指针相同；同拍 pop+push 会用新队尾覆盖已完成
// 的旧队首槽位，同时保持四项 occupancy。
// ============================================================================
module write_buffer (
    input  wire        clk,
    input  wire        reset,

    input  wire        enq_valid,
    output wire        enq_ready,
    input  wire [31:0] enq_addr,
    input  wire [ 2:0] enq_size,
    input  wire [ 3:0] enq_strb,
    input  wire [31:0] enq_data,

    output wire        mem_req,
    output wire [31:0] mem_addr,
    output wire [ 2:0] mem_size,
    output wire [ 3:0] mem_strb,
    output wire [31:0] mem_data,
    input  wire        mem_done,

    output wire        empty,
    input  wire [31:0] query_addr,
    output wire        line_conflict,
    input  wire [31:0] chip_query_addr,
    output wire        chip_conflict
);

reg [31:0] addr [0:3];
reg [ 2:0] size [0:3];
reg [ 3:0] strb [0:3];
reg [31:0] data [0:3];
reg [ 1:0] rd_ptr;
reg [ 1:0] wr_ptr;
reg [ 2:0] count;
reg [ 3:0] valid;
reg [ 3:0] valid_next;

wire pop  = (count != 3'd0) & mem_done;
wire push = enq_valid & enq_ready;

assign enq_ready = (count != 3'd4) | pop;
assign empty     = (count == 3'd0);
assign mem_req   = ~empty;
assign mem_addr  = addr[rd_ptr];
assign mem_size  = size[rd_ptr];
assign mem_strb  = strb[rd_ptr];
assign mem_data  = data[rd_ptr];

assign line_conflict = (valid[0] &
                        (addr[0][31:4] == query_addr[31:4])) |
                       (valid[1] &
                        (addr[1][31:4] == query_addr[31:4])) |
                       (valid[2] &
                        (addr[2][31:4] == query_addr[31:4])) |
                       (valid[3] &
                        (addr[3][31:4] == query_addr[31:4]));
assign chip_conflict = (valid[0] &
                        (addr[0][31:22] == chip_query_addr[31:22])) |
                       (valid[1] &
                        (addr[1][31:22] == chip_query_addr[31:22])) |
                       (valid[2] &
                        (addr[2][31:22] == chip_query_addr[31:22])) |
                       (valid[3] &
                        (addr[3][31:22] == chip_query_addr[31:22]));

// 先清除 pop 槽位、再设置 push 槽位。这样 full turnover 时即使
// rd_ptr == wr_ptr，push 也会显式获胜，槽位最终保持有效。
always @(*) begin
    valid_next = valid;
    if (pop)
        valid_next[rd_ptr] = 1'b0;
    if (push)
        valid_next[wr_ptr] = 1'b1;
end

always @(posedge clk) begin
    if (reset) begin
        rd_ptr <= 2'b0;
        wr_ptr <= 2'b0;
        count  <= 3'b0;
        valid  <= 4'b0;
    end else begin
        case ({push, pop})
        2'b10: count <= count + 3'd1;
        2'b01: count <= count - 3'd1;
        default: count <= count;
        endcase

        if (push)
            wr_ptr <= wr_ptr + 2'd1;
        if (pop)
            rd_ptr <= rd_ptr + 2'd1;
        valid <= valid_next;
    end
end

always @(posedge clk) begin
    if (push) begin
        addr[wr_ptr] <= enq_addr;
        size[wr_ptr] <= enq_size;
        strb[wr_ptr] <= enq_strb;
        data[wr_ptr] <= enq_data;
    end
end

endmodule
