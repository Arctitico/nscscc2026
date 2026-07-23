import cpu_pkg::*;

module regfile(
    input  wire        clk,
    // READ PORT 1
    input  preg_t      rf_raddr1,
    output wire [31:0] rf_rdata1,
    // READ PORT 2 
    input  preg_t      rf_raddr2,
    output wire [31:0] rf_rdata2,
    // READ PORT 3 
    input  preg_t      rf_raddr3,
    output wire [31:0] rf_rdata3,
    // READ PORT 4 
    input  preg_t      rf_raddr4,
    output wire [31:0] rf_rdata4,
    // WRITE PORT 1 
    input  wire [ 3:0] rf_we1,
    input  preg_t      rf_waddr1,
    input  wire [31:0] rf_wdata1,
    // WRITE PORT 2 
    input  wire [ 3:0] rf_we2,
    input  preg_t      rf_waddr2,
    input  wire [31:0] rf_wdata2
);

reg [31:0] rf[PREG_COUNT-1:0];

// WRITE: 两个写端口同时写同一寄存器时, 程序序靠后的 port2 优先
always @(posedge clk) begin
    if (|rf_we1 && rf_waddr1 != preg_t'(0))
        rf[rf_waddr1] <= rf_wdata1;
    if (|rf_we2 && rf_waddr2 != preg_t'(0))
        rf[rf_waddr2] <= rf_wdata2;
    // port2 的赋值在 port1 之后, Verilog 语义保证 port2 写入优先
end

// READ OUT 1
assign rf_rdata1 = (rf_raddr1 == preg_t'(0)) ? 32'b0 : rf[rf_raddr1];

// READ OUT 2
assign rf_rdata2 = (rf_raddr2 == preg_t'(0)) ? 32'b0 : rf[rf_raddr2];

// READ OUT 3
assign rf_rdata3 = (rf_raddr3 == preg_t'(0)) ? 32'b0 : rf[rf_raddr3];

// READ OUT 4
assign rf_rdata4 = (rf_raddr4 == preg_t'(0)) ? 32'b0 : rf[rf_raddr4];

endmodule
