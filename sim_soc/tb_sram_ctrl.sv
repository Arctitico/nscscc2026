`timescale 1ns/1ps

module tb_sram_ctrl #(
    parameter integer READ_CYCLES       = 3,
    parameter integer WRITE_CYCLES      = 3,
    parameter integer WRITE_HOLD_CYCLES = 1
);

reg         clk = 1'b0;
reg         reset = 1'b1;
wire [19:0] ram_addr;
wire [ 3:0] ram_be_n;
wire        ram_ce_n;
wire        ram_oe_n;
wire        ram_we_n;
wire        ram_wdrive;
wire [31:0] ram_wdat;
// 返回数据编码当前物理地址，同时检查 ram_addr 与 ok beat 没有错拍。
wire [31:0] ram_rdat = {12'ha5a, ram_addr};
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

task automatic fail(input [8*96-1:0] message);
begin
    // 此仿真器下 $finish(1) 仍可能返回 0；用 $fatal 保证 make 看见失败。
    $fatal(1, "SRAM CWF TEST FAILED (%0d/%0d/%0d): %0s",
           READ_CYCLES, WRITE_CYCLES, WRITE_HOLD_CYCLES, message);
end
endtask

task automatic launch_request(
    input [3:0]  request_wstrb,
    input [19:0] request_addr,
    input [31:0] request_wdata,
    input [2:0]  request_len,
    input        request_tag
);
begin
    @(negedge clk);
    req    = 1'b1;
    wstrb  = request_wstrb;
    addr   = request_addr;
    wdata  = request_wdata;
    tag_in = request_tag;
    len    = request_len;
    @(posedge clk);
    #1;
    if (ram_ce_n)
        fail("request was not accepted");
    @(negedge clk);
    req = 1'b0;
end
endtask

task automatic expect_first_access_after(input integer expected);
    integer observed;
begin
    // launch_request 返回在接收沿后的首个 negedge；把接收访问拍计为第 1 拍。
    observed = 1;
    while (!ok) begin
        @(negedge clk);
        observed = observed + 1;
        if (observed > expected + 1)
            fail("first ok arrived too late");
    end
    if (observed != expected) begin
        $display("expected first ok after %0d cycles, observed %0d",
                 expected, observed);
        fail("wrong first-access cycle count");
    end
end
endtask

task automatic check_read_pins;
begin
    if (ram_ce_n || ram_oe_n || !ram_we_n || ram_wdrive)
        fail("wrong read pin direction during burst");
    if (ram_be_n != 4'h0)
        fail("read byte enables are not all active");
end
endtask

task automatic run_cwf_burst(
    input [19:0] start_addr,
    input        expected_tag
);
    integer beat;
    integer gap;
    reg [1:0] expected_word;
    reg [19:0] expected_addr;
begin
    launch_request(4'b0000, start_addr, 32'b0, 3'd3, expected_tag);
    expect_first_access_after(READ_CYCLES);

    for (beat = 0; beat < 4; beat = beat + 1) begin
        expected_word = start_addr[1:0] + beat;
        expected_addr = {start_addr[19:2], expected_word};

        if (!ok)
            fail("missing burst ok");
        if (!busy)
            fail("busy dropped before burst completed");
        check_read_pins();
        if (ram_addr !== expected_addr) begin
            $display("beat %0d start=%05x addr=%05x expected=%05x",
                     beat, start_addr, ram_addr, expected_addr);
            fail("wrong critical-first/wrapped address sequence");
        end
        if (ram_addr[19:2] !== start_addr[19:2])
            fail("burst carried into the adjacent 16-byte line");
        if (rdata !== {12'ha5a, expected_addr})
            fail("returned data does not match current burst address");
        if (tag_out !== expected_tag)
            fail("tag changed during burst");
        if (beat_last !== (beat == 3))
            fail("beat_last was not asserted only on the fourth beat");

        if (beat != 3) begin
            gap = 0;
            // READ_CYCLES=1 时 ok 可连续为高，每拍仍是独立 beat。
            do begin
                @(negedge clk);
                gap = gap + 1;
                if (gap > READ_CYCLES + 1)
                    fail("next burst beat arrived too late");
            end while (!ok);
            if (gap != READ_CYCLES) begin
                $display("beat %0d gap=%0d expected=%0d",
                         beat, gap, READ_CYCLES);
                fail("wrong inter-beat spacing");
            end
        end
    end

    // 最后一个响应后的沿退休事务并恢复 idle 引脚。
    @(posedge clk);
    #1;
    if (!ram_ce_n || !ram_oe_n || !ram_we_n || busy || ok)
        fail("burst did not return cleanly to idle");
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

    // 保留原单字读检查。
    launch_request(4'b0000, 20'h12345, 32'b0, 3'd0, 1'b1);
    check_read_pins();
    expect_first_access_after(READ_CYCLES);
    if (!beat_last || rdata != {12'ha5a, 20'h12345} || tag_out != 1'b1)
        fail("wrong single-word read response");
    @(posedge clk);
    #1;
    if (!ram_ce_n || busy)
        fail("single-word read did not return to idle");

    // critical word offset 0..3 对应 0123/1230/2301/3012。
    run_cwf_burst(20'h12344, 1'b0);
    run_cwf_burst(20'h12345, 1'b1);
    run_cwf_burst(20'h12346, 1'b0);
    run_cwf_burst(20'h12347, 1'b1);

    // 顶部边界必须 fffff→ffffc，而不是向下一行/chip 进位。
    run_cwf_burst(20'hfffff, 1'b1);

    // 保留原写脉冲和写后保持检查。
    launch_request(4'b0101, 20'h23456, 32'h0123_4567, 3'd0, 1'b0);
    if (!ram_oe_n || ram_we_n || !ram_wdrive)
        fail("wrong write pin direction");
    expect_first_access_after(WRITE_CYCLES);
    if (!beat_last)
        fail("single-word write did not assert beat_last");
    held_addr  = ram_addr;
    held_wdata = ram_wdat;
    held_be_n  = ram_be_n;

    // ok 所在写末拍结束时 WE# 上升；随后必须完整保持指定拍数。
    @(posedge clk);
    #1;
    for (i = 0; i < WRITE_HOLD_CYCLES; i = i + 1) begin
        if (!ram_we_n || !ram_wdrive)
            fail("write data bus was released during hold");
        if (ram_addr != held_addr || ram_wdat != held_wdata ||
            ram_be_n != held_be_n)
            fail("write pins changed during hold");
        if ((i < WRITE_HOLD_CYCLES - 1) && !busy)
            fail("controller became ready before final hold cycle");
        @(posedge clk);
        #1;
    end
    if (ram_wdrive || busy || !ram_ce_n)
        fail("write hold did not finish cleanly");

    $display("SRAM CWF TEST PASSED (%0d/%0d/%0d)",
             READ_CYCLES, WRITE_CYCLES, WRITE_HOLD_CYCLES);
    $finish;
end

endmodule
