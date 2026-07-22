// ============================================================================
// 两项 FIFO 写缓冲：缓存普通 SRAM store，直到外部写响应返回。
//
// enqueue 与队首完成可同拍发生。对外只暴露 FIFO 队首，载荷在 mem_done
// 前保持稳定，满足 AXI bridge 的“请求保持到完成”约定。
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
    output wire        line_conflict
);

reg [31:0] addr [0:1];
reg [ 2:0] size [0:1];
reg [ 3:0] strb [0:1];
reg [31:0] data [0:1];
reg        rd_ptr;
reg        wr_ptr;
reg [ 1:0] count;

wire pop  = (count != 2'd0) & mem_done;
wire push = enq_valid & enq_ready;

assign enq_ready = (count != 2'd2) | pop;
assign empty     = (count == 2'd0);
assign mem_req   = ~empty;
assign mem_addr  = addr[rd_ptr];
assign mem_size  = size[rd_ptr];
assign mem_strb  = strb[rd_ptr];
assign mem_data  = data[rd_ptr];
wire valid0 = (count == 2'd2) | ((count == 2'd1) & (rd_ptr == 1'b0));
wire valid1 = (count == 2'd2) | ((count == 2'd1) & (rd_ptr == 1'b1));
assign line_conflict = (valid0 & (addr[0][31:4] == query_addr[31:4])) |
                       (valid1 & (addr[1][31:4] == query_addr[31:4]));

always @(posedge clk) begin
    if (reset) begin
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
    if (push) begin
        addr[wr_ptr] <= enq_addr;
        size[wr_ptr] <= enq_size;
        strb[wr_ptr] <= enq_strb;
        data[wr_ptr] <= enq_data;
    end
end

endmodule
