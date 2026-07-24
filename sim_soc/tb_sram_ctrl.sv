`timescale 1ns/1ps

module tb_sram_ctrl;

localparam integer READ_CYCLES       = 4;
localparam integer WRITE_CYCLES      = 3;
localparam integer WRITE_HOLD_CYCLES = 2;

reg         clk = 1'b0;
reg         reset = 1'b1;
wire [19:0] ram_addr;
wire [ 3:0] ram_be_n;
wire        ram_ce_n;
wire        ram_oe_n;
wire        ram_we_n;
wire        ram_wdrive;
wire [31:0] ram_wdat;
reg  [31:0] ram_rdat = 32'ha5a5_5a5a;
reg         req = 1'b0;
reg  [ 3:0] wstrb = 4'b0;
reg  [19:0] addr = 20'b0;
reg  [31:0] wdata = 32'b0;
reg  [ 2:0] len = 3'b0;
reg         tag_in = 1'b0;
wire        ok;
wire [31:0] rdata;
wire        beat_last;
wire        tag_out;
wire        busy;

always #5 clk = ~clk;

sram_ctrl #(
    .READ_CYCLES(READ_CYCLES),
    .WRITE_CYCLES(WRITE_CYCLES),
    .WRITE_HOLD_CYCLES(WRITE_HOLD_CYCLES)
) dut (
    .clk(clk),
    .reset(reset),
    .ram_addr(ram_addr),
    .ram_be_n(ram_be_n),
    .ram_ce_n(ram_ce_n),
    .ram_oe_n(ram_oe_n),
    .ram_we_n(ram_we_n),
    .ram_wdrive(ram_wdrive),
    .ram_wdat(ram_wdat),
    .ram_rdat(ram_rdat),
    .req(req),
    .wstrb(wstrb),
    .addr(addr),
    .wdata(wdata),
    .len(len),
    .tag_in(tag_in),
    .ok(ok),
    .rdata(rdata),
    .beat_last(beat_last),
    .tag_out(tag_out),
    .busy(busy)
);

task automatic fail(input [255:0] message);
begin
    $display("SRAM TIMING TEST FAILED: %0s", message);
    $finish(1);
end
endtask

task automatic launch_request(
    input [3:0]  request_wstrb,
    input [19:0] request_addr,
    input [31:0] request_wdata,
    input         request_tag
);
begin
    @(negedge clk);
    req    = 1'b1;
    wstrb  = request_wstrb;
    addr   = request_addr;
    wdata  = request_wdata;
    tag_in = request_tag;
    len    = 3'b0;
    @(posedge clk);
    #1;
    if (ram_ce_n)
        fail("request was not accepted");
    @(negedge clk);
    req = 1'b0;
end
endtask

task automatic expect_access_cycles(input integer expected);
    integer observed;
begin
    observed = 1;
    while (!ok) begin
        @(negedge clk);
        observed = observed + 1;
        if (observed > expected + 1)
            fail("ok arrived too late");
    end
    if (observed != expected) begin
        $display("expected %0d access cycles, observed %0d", expected, observed);
        fail("wrong access cycle count");
    end
end
endtask

integer i;
reg [19:0] held_addr;
reg [31:0] held_wdata;
reg [ 3:0] held_be_n;

initial begin
    repeat (3) @(posedge clk);
    @(negedge clk);
    reset = 1'b0;

    launch_request(4'b0000, 20'h12345, 32'b0, 1'b1);
    if (ram_oe_n || !ram_we_n || ram_wdrive)
        fail("wrong read pin direction");
    expect_access_cycles(READ_CYCLES);
    if (!beat_last || rdata != ram_rdat || tag_out != 1'b1)
        fail("wrong read response");
    @(posedge clk);
    #1;
    if (!ram_ce_n || busy)
        fail("read did not return to idle");

    launch_request(4'b0101, 20'h23456, 32'h0123_4567, 1'b0);
    if (!ram_oe_n || ram_we_n || !ram_wdrive)
        fail("wrong write pin direction");
    expect_access_cycles(WRITE_CYCLES);
    held_addr  = ram_addr;
    held_wdata = ram_wdat;
    held_be_n  = ram_be_n;

    // ok 所在写末拍结束时 WE# 上升；随后必须完整保持指定拍数。
    @(posedge clk);
    #1;
    for (i = 0; i < WRITE_HOLD_CYCLES; i = i + 1) begin
        if (!ram_we_n || !ram_wdrive)
            fail("write data bus was released during hold");
        if (ram_addr != held_addr || ram_wdat != held_wdata || ram_be_n != held_be_n)
            fail("write pins changed during hold");
        if ((i < WRITE_HOLD_CYCLES - 1) && !busy)
            fail("controller became ready before final hold cycle");
        @(posedge clk);
        #1;
    end
    if (ram_wdrive || busy || !ram_ce_n)
        fail("write hold did not finish cleanly");

    $display("SRAM TIMING TEST PASSED");
    $finish;
end

endmodule
