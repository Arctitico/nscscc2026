module regfile(
    input  wire        clk,
    // READ PORT 1
    input  wire [ 4:0] rf_raddr1,
    output wire [31:0] rf_rdata1,
    // READ PORT 2 
    input  wire [ 4:0] rf_raddr2,
    output wire [31:0] rf_rdata2,
    // READ PORT 3 
    input  wire [ 4:0] rf_raddr3,
    output wire [31:0] rf_rdata3,
    // READ PORT 4 
    input  wire [ 4:0] rf_raddr4,
    output wire [31:0] rf_rdata4,
    // WRITE PORT 1 
    input  wire [ 3:0] rf_we1,
    input  wire [ 4:0] rf_waddr1,
    input  wire [31:0] rf_wdata1,
    // WRITE PORT 2 
    input  wire [ 3:0] rf_we2,
    input  wire [ 4:0] rf_waddr2,
    input  wire [31:0] rf_wdata2
);

(* ram_style = "distributed" *) reg [31:0] rf_bank0 [0:31];
(* ram_style = "distributed" *) reg [31:0] rf_bank1 [0:31];
reg [31:0] latest_bank;

wire write0 = |rf_we1 && (rf_waddr1 != 5'b0);
wire write1 = |rf_we2 && (rf_waddr2 != 5'b0);

always @(posedge clk) begin
    if (write0)
        rf_bank0[rf_waddr1] <= rf_wdata1;
end

always @(posedge clk) begin
    if (write1)
        rf_bank1[rf_waddr2] <= rf_wdata2;
end

always @(posedge clk) begin
    if (write0)
        latest_bank[rf_waddr1] <= 1'b0;
    if (write1)
        latest_bank[rf_waddr2] <= 1'b1;
end

wire [31:0] bank0_rdata1 = rf_bank0[rf_raddr1];
wire [31:0] bank0_rdata2 = rf_bank0[rf_raddr2];
wire [31:0] bank0_rdata3 = rf_bank0[rf_raddr3];
wire [31:0] bank0_rdata4 = rf_bank0[rf_raddr4];
wire [31:0] bank1_rdata1 = rf_bank1[rf_raddr1];
wire [31:0] bank1_rdata2 = rf_bank1[rf_raddr2];
wire [31:0] bank1_rdata3 = rf_bank1[rf_raddr3];
wire [31:0] bank1_rdata4 = rf_bank1[rf_raddr4];

assign rf_rdata1 = (rf_raddr1 == 5'b0) ? 32'b0 :
                   (latest_bank[rf_raddr1] ? bank1_rdata1 : bank0_rdata1);
assign rf_rdata2 = (rf_raddr2 == 5'b0) ? 32'b0 :
                   (latest_bank[rf_raddr2] ? bank1_rdata2 : bank0_rdata2);
assign rf_rdata3 = (rf_raddr3 == 5'b0) ? 32'b0 :
                   (latest_bank[rf_raddr3] ? bank1_rdata3 : bank0_rdata3);
assign rf_rdata4 = (rf_raddr4 == 5'b0) ? 32'b0 :
                   (latest_bank[rf_raddr4] ? bank1_rdata4 : bank0_rdata4);

endmodule
