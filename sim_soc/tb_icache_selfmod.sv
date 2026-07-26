`timescale 1ns/1ps

module tb_icache_selfmod;

reg clk = 1'b0;
always #5 clk = ~clk;

reg         reset;
reg         store_valid;
reg  [31:0] store_addr;
reg         req;
reg  [31:0] addr;
wire        addr_ok;
wire        data_ok;
wire [31:0] rdata_lo;
wire [31:0] rdata_hi;
wire        inst_rd_req;
wire [31:0] inst_rd_addr;
reg         inst_rd_rdy;
reg         inst_ret_valid;
reg  [31:0] inst_ret_data;
reg         inst_ret_last;
wire        perf_miss;
wire        selfmod_hit;

// 与顶层相同：命中结果先登记，下一拍才用于全局 flush/全 cache 失效。
reg selfmod_flush;
wire flush = selfmod_flush;
always @(posedge clk) begin
    if (reset) selfmod_flush <= 1'b0;
    else       selfmod_flush <= selfmod_hit;
end

icache #(
    .IDX_BITS(2),
    .WORD_BITS(2)
) dut (
    .clk(clk),
    .reset(reset),
    .flush(flush),
    .store_valid(store_valid),
    .store_addr(store_addr),
    .invalidate_all(selfmod_flush),
    .selfmod_hit(selfmod_hit),
    .req(req),
    .addr(addr),
    .addr_ok(addr_ok),
    .data_ok(data_ok),
    .rdata_lo(rdata_lo),
    .rdata_hi(rdata_hi),
    .inst_rd_req(inst_rd_req),
    .inst_rd_addr(inst_rd_addr),
    .inst_rd_rdy(inst_rd_rdy),
    .inst_ret_valid(inst_ret_valid),
    .inst_ret_data(inst_ret_data),
    .inst_ret_last(inst_ret_last),
    .perf_miss(perf_miss)
);

localparam [2:0] S_IDLE     = 3'd0;
localparam [2:0] S_LOOKUP   = 3'd1;
localparam [2:0] S_REQ      = 3'd2;
localparam [2:0] S_FILL     = 3'd3;
localparam [2:0] S_RELOOKUP = 3'd4;

localparam [31:0] LINE_A = 32'h1c00_0100;
localparam [31:0] LINE_B = 32'h1c00_0140;
localparam [31:0] LINE_C = 32'h1c00_0280;
localparam [31:0] LINE_D = 32'h1c00_03c0;
localparam [31:0] LINE_E = 32'h1c00_0500;

task automatic issue_request(input [31:0] request_addr);
begin
    @(negedge clk);
    addr = request_addr;
    req = 1'b1;
    #1;
    if (!addr_ok)
        $fatal(1, "I-cache request was not accepted from IDLE");
    @(posedge clk);
    #1;
    if (dut.state != S_LOOKUP)
        $fatal(1, "accepted I-cache request did not enter LOOKUP");
    @(negedge clk);
    req = 1'b0;
end
endtask

task automatic accept_refill(input [31:0] line_addr);
begin
    if (!inst_rd_req || inst_rd_addr != line_addr)
        $fatal(1, "unexpected I-cache refill request");
    @(negedge clk);
    inst_rd_rdy = 1'b1;
    @(posedge clk);
    #1;
    if (dut.state != S_FILL)
        $fatal(1, "accepted refill did not enter FILL");
    @(negedge clk);
    inst_rd_rdy = 1'b0;
end
endtask

task automatic send_beat(input [31:0] data, input last);
begin
    @(negedge clk);
    inst_ret_data = data;
    inst_ret_last = last;
    inst_ret_valid = 1'b1;
    @(posedge clk);
    #1;
end
endtask

task automatic stop_return;
begin
    @(negedge clk);
    inst_ret_valid = 1'b0;
    inst_ret_last = 1'b0;
    inst_ret_data = 32'b0;
end
endtask

task automatic send_line(input [31:0] seed);
begin
    send_beat(seed + 32'd0, 1'b0);
    send_beat(seed + 32'd1, 1'b0);
    send_beat(seed + 32'd2, 1'b0);
    send_beat(seed + 32'd3, 1'b1);
    stop_return();
    // 消费登记后的最后一个 beat。
    @(posedge clk);
    #1;
end
endtask

task automatic wait_data(input [31:0] expected_lo,
                         input [31:0] expected_hi);
    integer cycles;
    reg found;
begin
    found = 1'b0;
    for (cycles = 0; cycles < 20; cycles = cycles + 1) begin
        @(posedge clk);
        #1;
        if (data_ok) begin
            if (rdata_lo != expected_lo || rdata_hi != expected_hi)
                $fatal(1, "wrong data %h/%h, expected %h/%h",
                       rdata_lo, rdata_hi, expected_lo, expected_hi);
            found = 1'b1;
            cycles = 20;
        end
    end
    if (!found)
        $fatal(1, "I-cache request never produced data_ok");
    @(posedge clk);
    #1;
    if (dut.state != S_IDLE)
        $fatal(1, "completed I-cache request did not return to IDLE");
end
endtask

task automatic fill_and_check(input [31:0] line_addr,
                              input [31:0] seed);
begin
    issue_request(line_addr);
    @(posedge clk);
    #1;
    if (dut.state != S_REQ)
        $fatal(1, "I-cache miss did not enter S_REQ");
    accept_refill(line_addr);
    send_line(seed);
    if (dut.state != S_RELOOKUP)
        $fatal(1, "clean refill did not enter RELOOKUP");
    wait_data(seed, seed + 32'd1);
end
endtask

task automatic finish_selfmod_event;
begin
    @(negedge clk);
    store_valid = 1'b0;
    @(posedge clk);
    #1;
    if (selfmod_flush)
        $fatal(1, "selfmod flush was not a one-cycle pulse");
    if (dut.valid0 != '0 || dut.valid1 != '0)
        $fatal(1, "selfmod flush did not clear both I-cache ways");
end
endtask

initial begin
    reset = 1'b1;
    store_valid = 1'b0;
    store_addr = 32'b0;
    req = 1'b0;
    addr = 32'b0;
    inst_rd_rdy = 1'b0;
    inst_ret_valid = 1'b0;
    inst_ret_data = 32'b0;
    inst_ret_last = 1'b0;

    repeat (4) @(negedge clk);
    reset = 1'b0;
    repeat (2) @(negedge clk);

    // 两个不同 tag、同一 set 的行同时驻留，matching store 必须全清两路。
    fill_and_check(LINE_A, 32'h1000_0000);
    fill_and_check(LINE_B, 32'h2000_0000);
    if (dut.valid0 == '0 || dut.valid1 == '0)
        $fatal(1, "resident setup did not populate both ways");

    // 不同 line 的普通 store 不应造成误 flush。
    @(negedge clk);
    store_addr = LINE_A + 32'h0000_1000;
    store_valid = 1'b1;
    #1;
    if (selfmod_hit)
        $fatal(1, "nonmatching store falsely hit instruction state");
    @(posedge clk);
    #1;
    if (selfmod_flush)
        $fatal(1, "nonmatching store generated selfmod flush");
    @(negedge clk);
    store_valid = 1'b0;

    // resident hit：事件登记后下一拍全清，不只清命中的一路。
    @(negedge clk);
    store_addr = LINE_A + 32'd4;
    store_valid = 1'b1;
    #1;
    if (!selfmod_hit)
        $fatal(1, "resident matching store did not trigger");
    @(posedge clk);
    #1;
    if (!selfmod_flush)
        $fatal(1, "resident event was not registered");
    if (data_ok)
        $fatal(1, "flush cycle exposed cached instruction data");
    finish_selfmod_event();

    // valid=0 仍要覆盖同拍刚接受的 fetch，否则它可能在 store 生效前开始。
    @(negedge clk);
    addr = LINE_C;
    req = 1'b1;
    store_addr = LINE_C + 32'd12;
    store_valid = 1'b1;
    #1;
    if (!addr_ok || !selfmod_hit)
        $fatal(1, "same-cycle accepted fetch was not matched");
    @(posedge clk);
    #1;
    if (!selfmod_flush || dut.state != S_LOOKUP)
        $fatal(1, "same-cycle fetch event was not registered");
    @(negedge clk);
    req = 1'b0;
    store_valid = 1'b0;
    @(posedge clk);
    #1;
    if (dut.state != S_IDLE || selfmod_flush)
        $fatal(1, "same-cycle fetch was not discarded by flush");

    // S_REQ 可在 flush 拍被外部接受；burst 无需取消，但最终绝不能置 valid。
    issue_request(LINE_D);
    @(posedge clk);
    #1;
    if (dut.state != S_REQ)
        $fatal(1, "active-request test did not reach S_REQ");
    @(negedge clk);
    store_addr = LINE_D + 32'd8;
    store_valid = 1'b1;
    #1;
    if (!selfmod_hit)
        $fatal(1, "S_REQ line was not treated as active");
    @(posedge clk);
    #1;
    if (!selfmod_flush)
        $fatal(1, "S_REQ match did not register an event");
    @(negedge clk);
    store_valid = 1'b0;
    inst_rd_rdy = 1'b1;
    @(posedge clk);
    #1;
    if (dut.state != S_FILL || !dut.refill_flushed)
        $fatal(1, "flush-accepted refill was not marked killed");
    @(negedge clk);
    inst_rd_rdy = 1'b0;
    send_line(32'h3000_0000);
    if (dut.state != S_IDLE || dut.valid0 != '0 || dut.valid1 != '0)
        $fatal(1, "killed refill committed a valid line");

    // refill_last 与 store hit 同沿：旧行可在该沿写阵列，但 flush 周期不可
    // 交付，下一沿必须全失效。
    issue_request(LINE_E);
    @(posedge clk);
    #1;
    accept_refill(LINE_E);
    send_beat(32'h4000_0000, 1'b0);
    send_beat(32'h4000_0001, 1'b0);
    send_beat(32'h4000_0002, 1'b0);
    send_beat(32'h4000_0003, 1'b1);
    @(negedge clk);
    inst_ret_valid = 1'b0;
    inst_ret_last = 1'b0;
    store_addr = LINE_E;
    store_valid = 1'b1;
    #1;
    if (!dut.refill_last || !selfmod_hit)
        $fatal(1, "refill_last boundary setup failed");
    @(posedge clk);
    #1;
    if (!selfmod_flush || data_ok)
        $fatal(1, "refill_last boundary exposed stale data");
    finish_selfmod_event();
    if (dut.state != S_IDLE)
        $fatal(1, "flushed refill did not return to IDLE");

    // 清空后同一行可正常从更新后的存储器重新填充。
    fill_and_check(LINE_E, 32'h5000_0000);

    $display("ICACHE SELFMOD FLUSH TEST PASSED");
    $finish;
end

endmodule
