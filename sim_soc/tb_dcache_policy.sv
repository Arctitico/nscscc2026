`timescale 1ns/1ps

module tb_dcache_policy;

reg clk = 1'b0;
always #5 clk = ~clk;

reg reset;
reg train_valid;
reg train_was_hit;
reg [31:0] train_pc;
reg [31:0] train_addr;
reg query_valid;
reg [31:0] query_pc;
wire query_word_only;
wire query_probe;
reg policy_feedback_valid;
reg policy_feedback_hit;
reg policy_feedback_probe;
reg [31:0] policy_feedback_pc;
wire candidate_valid;
wire [31:0] candidate_addr;
reg candidate_take;
wire policy_enter_event;
wire policy_exit_hit_event;
wire policy_exit_pattern_event;

dcache_prefetcher dut (
    .clk(clk),
    .reset(reset),
    .train_valid(train_valid),
    .train_was_hit(train_was_hit),
    .train_pc(train_pc),
    .train_addr(train_addr),
    .query_valid(query_valid),
    .query_pc(query_pc),
    .query_word_only(query_word_only),
    .query_probe(query_probe),
    .policy_feedback_valid(policy_feedback_valid),
    .policy_feedback_hit(policy_feedback_hit),
    .policy_feedback_probe(policy_feedback_probe),
    .policy_feedback_pc(policy_feedback_pc),
    .buffer_valid(2'b00),
    .buffer_line0(28'b0),
    .buffer_line1(28'b0),
    .refill_busy(1'b0),
    .refill_line(28'b0),
    .candidate_valid(candidate_valid),
    .candidate_addr(candidate_addr),
    .candidate_take(candidate_take),
    .policy_enter_event(policy_enter_event),
    .policy_exit_hit_event(policy_exit_hit_event),
    .policy_exit_pattern_event(policy_exit_pattern_event)
);

localparam [31:0] PC_RANDOM = 32'h1c00_2100;
localparam [31:0] PC_HIT    = 32'h1c00_2104;
localparam [31:0] PC_STABLE = 32'h1c00_2108;
localparam [31:0] PC_ALIAS2 = 32'h1c00_210c;
localparam [31:0] PC_SAME   = 32'h1c00_2110;
localparam [31:0] PC_ALIAS  = 32'h1c01_2100; // 与 PC_RANDOM 同 index
localparam [31:0] PC_ALIAS3 = 32'h1c03_210c; // 与 PC_ALIAS2 同 index

integer i;
integer enter_events;
integer exit_hit_events;
integer exit_pattern_events;

always @(posedge clk) begin
    if (reset) begin
        enter_events <= 0;
        exit_hit_events <= 0;
        exit_pattern_events <= 0;
    end else begin
        if (policy_enter_event)
            enter_events <= enter_events + 1;
        if (policy_exit_hit_event)
            exit_hit_events <= exit_hit_events + 1;
        if (policy_exit_pattern_event)
            exit_pattern_events <= exit_pattern_events + 1;
    end
end

task automatic train(
    input [31:0] pc,
    input [31:0] address,
    input        was_hit
);
begin
    @(negedge clk);
    train_pc = pc;
    train_addr = address;
    train_was_hit = was_hit;
    train_valid = 1'b1;
    @(negedge clk);
    train_valid = 1'b0;
    train_was_hit = 1'b0;
end
endtask

task automatic service(
    input [31:0] pc,
    input        is_probe
);
begin
    @(negedge clk);
    policy_feedback_pc = pc;
    policy_feedback_hit = 1'b0;
    policy_feedback_probe = is_probe;
    policy_feedback_valid = 1'b1;
    @(negedge clk);
    policy_feedback_valid = 1'b0;
    policy_feedback_probe = 1'b0;
end
endtask

task automatic prefetch_hit_feedback(
    input [31:0] pc,
    input [31:0] address
);
begin
    // 真实 stream-buffer 首次 hit 会同拍产生 predictor training 和
    // cache-hit feedback；同一次恢复只能计为 hit exit。
    @(negedge clk);
    train_pc = pc;
    train_addr = address;
    train_was_hit = 1'b1;
    train_valid = 1'b1;
    policy_feedback_pc = pc;
    policy_feedback_hit = 1'b1;
    policy_feedback_probe = 1'b0;
    policy_feedback_valid = 1'b1;
    @(negedge clk);
    train_valid = 1'b0;
    train_was_hit = 1'b0;
    policy_feedback_valid = 1'b0;
    policy_feedback_hit = 1'b0;
end
endtask

task automatic expect_policy(
    input [31:0] pc,
    input        expected_word,
    input        expected_probe,
    input [255:0] label
);
begin
    query_pc = pc;
    query_valid = 1'b1;
    #1;
    if (query_word_only !== expected_word ||
        query_probe !== expected_probe) begin
        $display("FAIL %0s: word=%b probe=%b expected %b/%b",
                 label, query_word_only, query_probe,
                 expected_word, expected_probe);
        $display(" idx=%0d valid=%b mode=%b samples=%0d score=%0d conf=%0d last=%h stride=%0d",
                 pc[4:2], dut.pred_valid[pc[4:2]],
                 dut.word_mode[pc[4:2]], dut.sample_count[pc[4:2]],
                 dut.low_score[pc[4:2]], dut.pred_conf[pc[4:2]],
                 dut.pred_last_line[pc[4:2]], dut.pred_stride[pc[4:2]]);
        $fatal(1);
    end
end
endtask

task automatic enter_random_mode(
    input [31:0] pc,
    input [31:0] base
);
begin
    train(pc, base + 32'h0000, 1'b0);
    expect_policy(pc, 1'b0, 1'b0, "cold sample 1");
    train(pc, base + 32'h1000, 1'b0);
    expect_policy(pc, 1'b0, 1'b0, "cold sample 2");
    train(pc, base + 32'h3000, 1'b0);
    expect_policy(pc, 1'b0, 1'b0, "cold sample 3");
    train(pc, base + 32'h6000, 1'b0);
    expect_policy(pc, 1'b1, 1'b0, "enter after sample 4");
end
endtask

initial begin
    reset = 1'b1;
    train_valid = 1'b0;
    train_was_hit = 1'b0;
    train_pc = 32'b0;
    train_addr = 32'b0;
    query_valid = 1'b0;
    query_pc = 32'b0;
    policy_feedback_valid = 1'b0;
    policy_feedback_hit = 1'b0;
    policy_feedback_probe = 1'b0;
    policy_feedback_pc = 32'b0;
    candidate_take = 1'b1;
    enter_events = 0;
    exit_hit_events = 0;
    exit_pattern_events = 0;

    repeat (3) @(negedge clk);
    reset = 1'b0;

    // 四个 irregular baseline 样本之前坚持完整行冷启动。
    enter_random_mode(PC_RANDOM, 32'h1c10_0000);

    // 15 次实际 word service 后，第 16 次分类 miss 强制完整行 probe。
    // 重复 query 不得提前消费 due probe。
    for (i = 0; i < 15; i = i + 1) begin
        service(PC_RANDOM, 1'b0);
        if (i < 14)
            expect_policy(PC_RANDOM, 1'b1, 1'b0,
                          "word service before probe");
    end
    expect_policy(PC_RANDOM, 1'b0, 1'b1, "periodic probe due");
    expect_policy(PC_RANDOM, 1'b0, 1'b1, "probe query does not consume");
    service(PC_RANDOM, 1'b1);
    expect_policy(PC_RANDOM, 1'b1, 1'b0, "probe service resets period");

    // 相位转为固定非零 stride 后，必须到 confidence=2 才退出。
    train(PC_RANDOM, 32'h1c16_0400, 1'b0);
    expect_policy(PC_RANDOM, 1'b1, 1'b0, "stable recovery sample 1");
    train(PC_RANDOM, 32'h1c16_0800, 1'b0);
    expect_policy(PC_RANDOM, 1'b1, 1'b0, "stable recovery sample 2");
    train(PC_RANDOM, 32'h1c16_0c00, 1'b0);
    expect_policy(PC_RANDOM, 1'b1, 1'b0, "stable recovery sample 3");
    train(PC_RANDOM, 32'h1c16_1000, 1'b0);
    expect_policy(PC_RANDOM, 1'b0, 1'b0, "stable stride exits");

    // 冷启动就是稳定 stream 的 PC 不得进入 word mode。
    train(PC_STABLE, 32'h1c20_0000, 1'b0);
    train(PC_STABLE, 32'h1c20_0010, 1'b0);
    train(PC_STABLE, 32'h1c20_0020, 1'b0);
    train(PC_STABLE, 32'h1c20_0030, 1'b0);
    train(PC_STABLE, 32'h1c20_0040, 1'b0);
    expect_policy(PC_STABLE, 1'b0, 1'b0,
                  "stable cold stream stays fill");

    // 任意真实 cache/stream-buffer hit 都是 allocation 有用的强证据。
    enter_random_mode(PC_HIT, 32'h1c30_0000);
    prefetch_hit_feedback(PC_HIT, 32'h1c30_8000);
    expect_policy(PC_HIT, 1'b0, 1'b0, "cache hit exits");

    // 同一 line 的复用也退出，并且不把原非零 stride 覆盖为零。
    enter_random_mode(PC_SAME, 32'h1c38_0000);
    train(PC_SAME, 32'h1c38_6000, 1'b0);
    expect_policy(PC_SAME, 1'b0, 1'b0, "same-line reuse exits");

    // full-tag alias replacement 必须清除旧 mode/score/probe。
    enter_random_mode(PC_ALIAS2, 32'h1c40_0000);
    train(PC_ALIAS3, 32'h1c50_0000, 1'b0);
    expect_policy(PC_ALIAS3, 1'b0, 1'b0, "alias new PC cold reset");
    expect_policy(PC_ALIAS2, 1'b0, 1'b0, "alias old PC no stale mode");

    train(PC_ALIAS, 32'h1c60_0000, 1'b0);
    expect_policy(PC_ALIAS, 1'b0, 1'b0, "second alias cold reset");
    expect_policy(PC_RANDOM, 1'b0, 1'b0, "second alias evicts old tag");

    // 事件口只供仿真画像，核对进入与两种恢复路径确实发生。
    repeat (2) @(posedge clk);
    if (enter_events != 4 || exit_hit_events != 1 ||
        exit_pattern_events != 2) begin
        $display("event mismatch enter=%0d hit=%0d pattern=%0d",
                 enter_events, exit_hit_events, exit_pattern_events);
        $fatal(1);
    end

    $display("DCACHE ADAPTIVE POLICY TEST PASSED");
    $finish;
end

endmodule
