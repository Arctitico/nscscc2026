`timescale 1ns/1ps

module tb_dcache_adaptive;

reg clk = 1'b0;
always #5 clk = ~clk;

reg         reset;
reg         cpu_req;
reg  [ 3:0] cpu_we;
reg  [ 2:0] cpu_size;
reg  [31:0] cpu_addr;
reg  [31:0] cpu_wdata;
reg  [31:0] cpu_pc;
wire        cpu_addr_ok;
wire [31:0] cpu_rdata;
wire        cpu_data_ok;

wire        mem_rd_req;
wire [ 2:0] mem_rd_size;
wire [31:0] mem_rd_addr;
reg  [31:0] mem_rdata;
reg         mem_rd_ok;
wire        mem_wr_req;
wire [ 2:0] mem_wr_size;
wire [31:0] mem_wr_addr;
wire [ 3:0] mem_wr_strb;
wire [31:0] mem_wr_data;
reg         mem_wr_ok;

wire inst_safe;
wire perf_hit;
wire perf_miss;
wire perf_wb_stall;

dcache dut (
    .clk(clk),
    .reset(reset),
    .cpu_req(cpu_req),
    .cpu_we(cpu_we),
    .cpu_size(cpu_size),
    .cpu_addr(cpu_addr),
    .cpu_wdata(cpu_wdata),
    .cpu_pc(cpu_pc),
    .cpu_addr_ok(cpu_addr_ok),
    .cpu_rdata(cpu_rdata),
    .cpu_data_ok(cpu_data_ok),
    .mem_rd_req(mem_rd_req),
    .mem_rd_size(mem_rd_size),
    .mem_rd_addr(mem_rd_addr),
    .mem_rdata(mem_rdata),
    .mem_rd_ok(mem_rd_ok),
    .mem_wr_req(mem_wr_req),
    .mem_wr_size(mem_wr_size),
    .mem_wr_addr(mem_wr_addr),
    .mem_wr_strb(mem_wr_strb),
    .mem_wr_data(mem_wr_data),
    .mem_wr_ok(mem_wr_ok),
    .inst_safe(inst_safe),
    .perf_hit(perf_hit),
    .perf_miss(perf_miss),
    .perf_wb_stall(perf_wb_stall)
);

localparam [2:0] S_IDLE      = 3'd0;
localparam [2:0] S_LOOKUP    = 3'd1;
localparam [2:0] S_WAIT_WB   = 3'd2;
localparam [2:0] S_REFILL    = 3'd3;
localparam [2:0] S_WORD_READ = 3'd7;

localparam [31:0] PC_WORD     = 32'h1c00_2100;
localparam [31:0] PC_PROBE    = 32'h1c00_2104;
localparam [31:0] PC_WAIT     = 32'h1c00_2108;
localparam [31:0] PC_COLLIDE  = 32'h1c00_210c;

localparam [31:0] ADDR_WORD   = 32'h1c10_0029;
localparam [31:0] ADDR_PROBE  = 32'h1c12_003c;
localparam [31:0] ADDR_WAIT   = 32'h1c14_0044;
localparam [31:0] ADDR_COLLIDE = 32'h1c16_0088;
localparam [31:0] ADDR_DIRECT  = 32'h1c18_0090;

integer cpu_response_count;
integer refill_beat_count;
integer word_start_count;
integer probe_start_count;
integer mem_read_start_count;
reg     mem_rd_req_q;

always @(posedge clk) begin
    if (reset) begin
        cpu_response_count <= 0;
        refill_beat_count <= 0;
        word_start_count <= 0;
        probe_start_count <= 0;
        mem_read_start_count <= 0;
        mem_rd_req_q <= 1'b0;
    end else begin
        mem_rd_req_q <= mem_rd_req;
        if (cpu_data_ok)
            cpu_response_count <= cpu_response_count + 1;
        if (dut.refill_fire)
            refill_beat_count <= refill_beat_count + 1;
        if (dut.policy_word_start)
            word_start_count <= word_start_count + 1;
        if (dut.policy_probe_start)
            probe_start_count <= probe_start_count + 1;
        if (mem_rd_req && !mem_rd_req_q)
            mem_read_start_count <= mem_read_start_count + 1;
    end
end

task automatic seed_policy(
    input [31:0] pc,
    input [31:0] address,
    input [ 3:0] services
);
    integer idx;
begin
    idx = pc[4:2];
    @(negedge clk);
    dut.u_prefetcher.pred_valid[idx] = 1'b1;
    dut.u_prefetcher.pred_pc_tag[idx] = pc[31:5];
    dut.u_prefetcher.pred_last_line[idx] = address[31:4] - 28'd17;
    dut.u_prefetcher.pred_stride[idx] = 28'sd0;
    dut.u_prefetcher.pred_conf[idx] = 2'b00;
    dut.u_prefetcher.low_score[idx] = 3'd4;
    dut.u_prefetcher.sample_count[idx] = 3'd7;
    dut.u_prefetcher.word_mode[idx] = 1'b1;
    dut.u_prefetcher.probe_count[idx] = services;
end
endtask

task automatic start_request(
    input [31:0] pc,
    input [31:0] address,
    input [ 2:0] size,
    input [ 3:0] write_strobe,
    input [31:0] write_data
);
begin
    @(negedge clk);
    if (!cpu_addr_ok)
        $fatal(1, "request issued while dcache not ready");
    cpu_pc = pc;
    cpu_addr = address;
    cpu_size = size;
    cpu_we = write_strobe;
    cpu_wdata = write_data;
    cpu_req = 1'b1;
    @(posedge clk);
    #1;
    if (dut.state != S_LOOKUP)
        $fatal(1, "accepted request did not enter LOOKUP");
    @(negedge clk);
    cpu_req = 1'b0;
    cpu_we = 4'b0;
end
endtask

task automatic return_read_beat(
    input [31:0] data,
    input        expect_cpu_response
);
begin
    @(negedge clk);
    if (!mem_rd_req)
        $fatal(1, "read response supplied without mem_rd_req");
    mem_rdata = data;
    mem_rd_ok = 1'b1;
    #1;
    if (cpu_data_ok !== expect_cpu_response)
        $fatal(1, "unexpected cpu_data_ok on returned read beat");
    if (expect_cpu_response && cpu_rdata !== data)
        $fatal(1, "critical/word data mismatch");
    @(posedge clk);
    #1;
    @(negedge clk);
    mem_rd_ok = 1'b0;
    mem_rdata = 32'b0;
end
endtask

integer word_set;
integer probe_set;
integer wait_idx;
integer responses_before;
integer refills_before;
integer word_starts_before;
integer probe_starts_before;
integer read_starts_before;

initial begin
    reset = 1'b1;
    cpu_req = 1'b0;
    cpu_we = 4'b0;
    cpu_size = 3'b010;
    cpu_addr = 32'b0;
    cpu_wdata = 32'b0;
    cpu_pc = 32'b0;
    mem_rdata = 32'b0;
    mem_rd_ok = 1'b0;
    mem_wr_ok = 1'b0;

    repeat (4) @(negedge clk);
    reset = 1'b0;
    repeat (2) @(negedge clk);

    // Word-only：hint 在 accept 沿锁存；之后即使表项变化，仍走原 size
    // 的单拍读取，不触发 refill，也不分配 cache line。
    word_set = ADDR_WORD[10:4];
    seed_policy(PC_WORD, ADDR_WORD, 4'd0);
    responses_before = cpu_response_count;
    refills_before = refill_beat_count;
    word_starts_before = word_start_count;
    start_request(PC_WORD, ADDR_WORD, 3'b000, 4'b0, 32'b0);
    dut.u_prefetcher.word_mode[PC_WORD[4:2]] = 1'b0;
    @(posedge clk);
    #1;
    if (dut.state != S_WORD_READ)
        $fatal(1, "latched word-only hint did not select S_WORD_READ");
    if (!mem_rd_req || mem_rd_size != 3'b000 ||
        mem_rd_addr != ADDR_WORD)
        $fatal(1, "word-only request did not preserve address/size");
    repeat (2) begin
        @(posedge clk);
        #1;
        if (dut.state != S_WORD_READ || !mem_rd_req)
            $fatal(1, "word-only request was not held under backpressure");
    end
    return_read_beat(32'h89ab_cdef, 1'b1);
    @(posedge clk);
    #1;
    if (dut.state != S_IDLE)
        $fatal(1, "word-only response did not return to IDLE");
    if (cpu_response_count != responses_before + 1 ||
        word_start_count != word_starts_before + 1 ||
        refill_beat_count != refills_before)
        $fatal(1, "word-only transaction counters mismatch");
    if (dut.valid0[word_set] || dut.valid1[word_set])
        $fatal(1, "word-only transaction allocated a cache line");

    // Probe：第 16 次服务恢复完整四拍 CWF。offset=3 必须以 word3
    // 首返，然后按 0/1/2 回绕；只有首拍产生 CPU response，尾拍分配。
    probe_set = ADDR_PROBE[10:4];
    seed_policy(PC_PROBE, ADDR_PROBE, 4'd15);
    responses_before = cpu_response_count;
    refills_before = refill_beat_count;
    probe_starts_before = probe_start_count;
    start_request(PC_PROBE, ADDR_PROBE, 3'b010, 4'b0, 32'b0);
    @(posedge clk);
    #1;
    if (dut.state != S_REFILL)
        $fatal(1, "due probe did not select full-line refill");
    if (!mem_rd_req || mem_rd_size != 3'b100 ||
        mem_rd_addr != ADDR_PROBE)
        $fatal(1, "probe did not issue CWF line request");
    return_read_beat(32'haaaa_0003, 1'b1);
    return_read_beat(32'haaaa_0000, 1'b0);
    return_read_beat(32'haaaa_0001, 1'b0);
    return_read_beat(32'haaaa_0002, 1'b0);
    @(posedge clk);
    #1;
    if (dut.state != S_IDLE)
        $fatal(1, "probe refill did not return to IDLE");
    if (cpu_response_count != responses_before + 1 ||
        probe_start_count != probe_starts_before + 1 ||
        refill_beat_count != refills_before + 4)
        $fatal(1, "probe transaction counters mismatch");
    if (!dut.valid0[probe_set] || dut.valid1[probe_set])
        $fatal(1, "probe did not allocate expected victim way");
    if (dut.data0_mem[probe_set * 4 + 0] != 32'haaaa_0000 ||
        dut.data0_mem[probe_set * 4 + 1] != 32'haaaa_0001 ||
        dut.data0_mem[probe_set * 4 + 2] != 32'haaaa_0002 ||
        dut.data0_mem[probe_set * 4 + 3] != 32'haaaa_0003)
        $fatal(1, "probe CWF data landed in wrong word slots");

    // candidate 在空槽生成的同拍，若 CPU demand 恰好访问同一 line，
    // 应过滤这条冗余 prefetch，让 demand 只发起一次完整行读取。
    responses_before = cpu_response_count;
    refills_before = refill_beat_count;
    read_starts_before = mem_read_start_count;
    @(negedge clk);
    if (!cpu_addr_ok)
        $fatal(1, "collision demand issued while dcache not ready");
    dut.u_prefetcher.predict_s1_valid = 1'b1;
    dut.u_prefetcher.predict_s1_line = ADDR_COLLIDE[31:4] - 28'd1;
    dut.u_prefetcher.predict_s1_stride = 28'sd1;
    cpu_pc = PC_COLLIDE;
    cpu_addr = ADDR_COLLIDE;
    cpu_size = 3'b010;
    cpu_we = 4'b0;
    cpu_req = 1'b1;
    #1;
    if (!dut.pf_candidate_valid ||
        dut.pf_candidate_addr != {ADDR_COLLIDE[31:4], 4'b0} ||
        dut.pf_start)
        $fatal(1, "same-line candidate was not filtered");
    @(posedge clk);
    #1;
    if (dut.state != S_LOOKUP || dut.pf_busy)
        $fatal(1, "filtered candidate still started a prefetch");
    @(negedge clk);
    cpu_req = 1'b0;
    @(posedge clk);
    #1;
    if (dut.state != S_REFILL)
        $fatal(1, "same-line demand did not start its sole refill");
    return_read_beat(32'hbbbb_0002, 1'b1);
    return_read_beat(32'hbbbb_0003, 1'b0);
    return_read_beat(32'hbbbb_0000, 1'b0);
    return_read_beat(32'hbbbb_0001, 1'b0);
    @(posedge clk);
    #1;
    if (dut.state != S_IDLE ||
        cpu_response_count != responses_before + 1 ||
        refill_beat_count != refills_before + 4 ||
        mem_read_start_count != read_starts_before + 1)
        $fatal(1, "candidate/demand same-line transaction counted twice");

    // 同线过滤不能把 candidate 直通整体改成晚一拍。无 demand 时，
    // 新 candidate 仍必须在产生的同一拍启动一次 prefetch。
    responses_before = cpu_response_count;
    read_starts_before = mem_read_start_count;
    @(negedge clk);
    dut.u_prefetcher.predict_s1_valid = 1'b1;
    dut.u_prefetcher.predict_s1_line = ADDR_DIRECT[31:4] - 28'd1;
    dut.u_prefetcher.predict_s1_stride = 28'sd1;
    #1;
    if (!dut.pf_candidate_valid ||
        dut.pf_candidate_addr != {ADDR_DIRECT[31:4], 4'b0} ||
        !dut.pf_start)
        $fatal(1, "ordinary candidate lost same-cycle direct start");
    @(posedge clk);
    #1;
    if (!dut.pf_busy ||
        dut.pf_active_addr != {ADDR_DIRECT[31:4], 4'b0})
        $fatal(1, "direct candidate did not start prefetch");
    return_read_beat(32'hcccc_0000, 1'b0);
    return_read_beat(32'hcccc_0001, 1'b0);
    return_read_beat(32'hcccc_0002, 1'b0);
    return_read_beat(32'hcccc_0003, 1'b0);
    @(posedge clk);
    #1;
    if (dut.pf_busy ||
        cpu_response_count != responses_before ||
        mem_read_start_count != read_starts_before + 1)
        $fatal(1, "direct candidate transaction counters mismatch");

    // 同 line store 尚在 WB 时，word-only load 必须停在 WAIT_WB，
    // 不能提前启动或消费 service 计数；写完成后才发出单拍读。
    start_request(32'h1c00_2200, ADDR_WAIT, 3'b010,
                  4'b1111, 32'h1234_5678);
    #1;
    if (inst_safe)
        $fatal(1, "accepted store exposed an inst_safe gap before WB enqueue");
    @(posedge clk);
    #1;
    if (dut.state != S_IDLE || !mem_wr_req)
        $fatal(1, "cacheable store did not enter write buffer");
    seed_policy(PC_WAIT, ADDR_WAIT + 32'd4, 4'd0);
    wait_idx = PC_WAIT[4:2];
    word_starts_before = word_start_count;
    start_request(PC_WAIT, ADDR_WAIT + 32'd4,
                  3'b010, 4'b0, 32'b0);
    @(posedge clk);
    #1;
    if (dut.state != S_WAIT_WB || mem_rd_req ||
        word_start_count != word_starts_before ||
        dut.u_prefetcher.probe_count[wait_idx] != 4'd0)
        $fatal(1, "word-only service advanced before WB conflict cleared");
    repeat (2) begin
        @(posedge clk);
        #1;
        if (dut.state != S_WAIT_WB || mem_rd_req ||
            word_start_count != word_starts_before ||
            dut.u_prefetcher.probe_count[wait_idx] != 4'd0)
            $fatal(1, "WB wait consumed adaptive service");
    end
    @(negedge clk);
    if (!mem_wr_req || mem_wr_addr != ADDR_WAIT)
        $fatal(1, "unexpected write-buffer head");
    mem_wr_ok = 1'b1;
    @(posedge clk);
    #1;
    @(negedge clk);
    mem_wr_ok = 1'b0;
    @(posedge clk);
    #1;
    if (dut.state != S_WORD_READ || !mem_rd_req ||
        word_start_count != word_starts_before + 1 ||
        dut.u_prefetcher.probe_count[wait_idx] != 4'd1)
        $fatal(1, "word-only service did not start after WB drain");
    return_read_beat(32'h7654_3210, 1'b1);
    @(posedge clk);
    #1;
    if (dut.state != S_IDLE)
        $fatal(1, "post-WB word-only read did not complete");

    $display("DCACHE ADAPTIVE INTEGRATION TEST PASSED");
    $finish;
end

endmodule
