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
    input  wire [31:0] rf_wdata2,
    // WRITE PORT 3
    input  wire [ 3:0] rf_we3,
    input  preg_t      rf_waddr3,
    input  wire [31:0] rf_wdata3
);

reg [31:0] rf[PREG_COUNT-1:0];

// WRITE: fast completion 使用 port1/2，独立 LSU completion 使用 port3。
// 物理目的 tag 唯一，正常执行不会同拍写同一寄存器。
always @(posedge clk) begin
    if (|rf_we1 && rf_waddr1 != preg_t'(0))
        rf[rf_waddr1] <= rf_wdata1;
    if (|rf_we2 && rf_waddr2 != preg_t'(0))
        rf[rf_waddr2] <= rf_wdata2;
    if (|rf_we3 && rf_waddr3 != preg_t'(0))
        rf[rf_waddr3] <= rf_wdata3;
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
