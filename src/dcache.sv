// ============================================================================
// 透明数据 Cache（软件仍由 CPUCFG 看到“无 Cache”）
//
// - 4 KiB、2 路组相联、16B cache line，write-through/no-write-allocate。
// - BaseRAM/ExtRAM 0x1c000000-0x1c7fffff 可缓存；UART/其余地址旁路。
// - 普通 SRAM store 命中时更新 cache，同时进入四项 write buffer；miss 时
//   no-write-allocate，仍由四项 write buffer 写内存。
// - 普通 load miss 发起 critical-word-first 四 beat 重填。识别为低局部性的
//   load PC 改走单 word/no-allocate，并周期性恢复完整行 probe。
//   外部 size=3'b100 是本核内部的“16B line”编码。
// - 指令 miss 只有在 write buffer 排空后才能发出，保证自修改代码可见。
// ============================================================================
module dcache_prefetcher (
    input  wire        clk,
    input  wire        reset,

    input  wire        train_valid,
    input  wire        train_was_hit,
    input  wire [31:0] train_pc,
    input  wire [31:0] train_addr,

    // 只连接到 D-cache 的 request-capture 寄存器，不能直接控制 FSM。
    input  wire        query_valid,
    input  wire [31:0] query_pc,
    output wire        query_word_only,
    output wire        query_probe,

    // hit，或真正开始的 word-only/probe 服务反馈。
    input  wire        policy_feedback_valid,
    input  wire        policy_feedback_hit,
    input  wire        policy_feedback_probe,
    input  wire [31:0] policy_feedback_pc,

    input  wire [ 1:0] buffer_valid,
    input  wire [27:0] buffer_line0,
    input  wire [27:0] buffer_line1,
    input  wire        refill_busy,
    input  wire [27:0] refill_line,

    output wire        candidate_valid,
    output wire [31:0] candidate_addr,
    input  wire        candidate_take,

    output reg         policy_enter_event,
    output reg         policy_exit_hit_event,
    output reg         policy_exit_pattern_event
);

localparam [2:0] ENTER_SCORE     = 3'd3;
localparam [2:0] COLD_SAMPLES    = 3'd4;
localparam [3:0] PROBE_DUE_COUNT = 4'd15;

reg [7:0] pred_valid;
reg [26:0] pred_pc_tag [0:7];
reg [27:0] pred_last_line [0:7];
reg signed [27:0] pred_stride [0:7];
reg [1:0] pred_conf [0:7];

// 分类状态与同一个 full-tagged PC 表项绑定。新 PC/alias 一律从完整行冷启动。
reg [2:0] low_score [0:7];
reg [2:0] sample_count [0:7];
reg       word_mode [0:7];
reg [3:0] probe_count [0:7];

// 这三位同时寻址多组 stride/policy LUTRAM，物理扇出远高于逻辑上的表项
// 数量。允许综合器复制地址驱动，缩短 req_pc -> predictor table 的布线。
(* max_fanout = 32 *) wire [2:0] train_idx = train_pc[4:2];
wire [27:0] train_line = train_addr[31:4];
wire train_match = pred_valid[train_idx] &&
                   (pred_pc_tag[train_idx] == train_pc[31:5]);
wire signed [27:0] observed_stride =
    $signed(train_line) - $signed(pred_last_line[train_idx]);
wire stride_match = observed_stride == pred_stride[train_idx];
wire stride_zero = observed_stride == 28'sd0;
wire [1:0] next_conf =
    stride_match ?
        (pred_conf[train_idx] == 2'b11 ? 2'b11 :
                                              pred_conf[train_idx] + 1'b1) :
        (pred_conf[train_idx] == 2'b00 ? 2'b00 :
                                              pred_conf[train_idx] - 1'b1);
wire signed [27:0] next_stride =
    (!stride_match && pred_conf[train_idx] == 2'b00) ?
        observed_stride : pred_stride[train_idx];

wire train_bad = ~train_was_hit && ~stride_zero && ~stride_match &&
                 (pred_conf[train_idx] == 2'b00);
wire train_good = train_was_hit || stride_zero || stride_match;
wire stable_exit = ~stride_zero && stride_match && next_conf[1];
wire enter_now = train_bad &&
                 (sample_count[train_idx] >= COLD_SAMPLES - 1'b1) &&
                 (low_score[train_idx] >= ENTER_SCORE - 1'b1);

wire [2:0] query_idx = query_pc[4:2];
wire query_match = pred_valid[query_idx] &&
                   (pred_pc_tag[query_idx] == query_pc[31:5]);
wire query_mode = query_valid && query_match && word_mode[query_idx];
wire query_probe_due = probe_count[query_idx] == PROBE_DUE_COUNT;
assign query_word_only = query_mode && ~query_probe_due;
assign query_probe = query_mode && query_probe_due;

wire [2:0] feedback_idx = policy_feedback_pc[4:2];
wire feedback_match = pred_valid[feedback_idx] &&
                      (pred_pc_tag[feedback_idx] ==
                       policy_feedback_pc[31:5]);

// Stage 1：保持原 stride/confidence 学习，同时更新独立的 allocation policy。
// word mode 中的同 line 访问是恢复证据，不用 delta=0 覆盖已有非零 stride。
reg               predict_s1_valid;
reg [27:0]        predict_s1_line;
reg signed [27:0] predict_s1_stride;

always @(posedge clk) begin
    if (reset) begin
        pred_valid <= 8'b0;
        predict_s1_valid <= 1'b0;
        policy_enter_event <= 1'b0;
        policy_exit_hit_event <= 1'b0;
        policy_exit_pattern_event <= 1'b0;
    end else begin
        predict_s1_valid <= 1'b0;
        policy_enter_event <= 1'b0;
        policy_exit_hit_event <= 1'b0;
        policy_exit_pattern_event <= 1'b0;

        // 任意真实 cache/stream-buffer hit 都说明 allocation 仍有价值。
        // 若同拍 train 替换 alias 表项，下面的冷启动赋值优先。
        if (policy_feedback_valid && policy_feedback_hit &&
            feedback_match) begin
            if (word_mode[feedback_idx])
                policy_exit_hit_event <= 1'b1;
            low_score[feedback_idx] <= 3'd0;
            word_mode[feedback_idx] <= 1'b0;
            probe_count[feedback_idx] <= 4'd0;
        end

        // 只统计真正开始的服务，不在 query 时提前消费 probe。
        if (policy_feedback_valid && ~policy_feedback_hit &&
            feedback_match && word_mode[feedback_idx]) begin
            if (policy_feedback_probe) begin
                probe_count[feedback_idx] <= 4'd0;
            end else if (probe_count[feedback_idx] != PROBE_DUE_COUNT) begin
                probe_count[feedback_idx] <=
                    probe_count[feedback_idx] + 1'b1;
            end
        end

        if (train_valid) begin
            if (!train_match) begin
                pred_valid[train_idx] <= 1'b1;
                pred_pc_tag[train_idx] <= train_pc[31:5];
                pred_last_line[train_idx] <= train_line;
                pred_stride[train_idx] <= 28'sd0;
                pred_conf[train_idx] <= 2'b00;
                low_score[train_idx] <= 3'd0;
                sample_count[train_idx] <= 3'd1;
                word_mode[train_idx] <= 1'b0;
                probe_count[train_idx] <= 4'd0;
            end else begin
                if (sample_count[train_idx] != 3'b111)
                    sample_count[train_idx] <=
                        sample_count[train_idx] + 1'b1;

                if (!(word_mode[train_idx] && stride_zero)) begin
                    pred_last_line[train_idx] <= train_line;
                    pred_stride[train_idx] <= next_stride;
                    pred_conf[train_idx] <= next_conf;
                    predict_s1_valid <= next_conf[1] &&
                                        (next_stride != 0) &&
                                        ~word_mode[train_idx];
                    predict_s1_line <= train_line;
                    predict_s1_stride <= next_stride;
                end

                if (train_was_hit || stride_zero || stable_exit) begin
                    // prefetch hit 已由上面的 feedback 分支记为 hit exit；
                    // 这里只为同 line/stable-stride 恢复记 pattern exit。
                    if (word_mode[train_idx] && ~train_was_hit)
                        policy_exit_pattern_event <= 1'b1;
                    low_score[train_idx] <= 3'd0;
                    word_mode[train_idx] <= 1'b0;
                    probe_count[train_idx] <= 4'd0;
                end else begin
                    if (train_good) begin
                        low_score[train_idx] <=
                            (low_score[train_idx] <= 3'd2) ? 3'd0 :
                            low_score[train_idx] - 3'd2;
                    end else if (train_bad &&
                                 low_score[train_idx] != 3'b111) begin
                        low_score[train_idx] <=
                            low_score[train_idx] + 1'b1;
                    end

                    if (!word_mode[train_idx] && enter_now) begin
                        word_mode[train_idx] <= 1'b1;
                        probe_count[train_idx] <= 4'd0;
                        policy_enter_event <= 1'b1;
                    end
                end
            end
        end
    end
end

// Stage 2：生成 predicted line、过滤重复，并保持到 D-cache 接受。
reg        candidate_valid_r;
reg [27:0] candidate_line_r;

wire [27:0] predicted_line =
    $unsigned($signed(predict_s1_line) + predict_s1_stride);
wire predicted_cacheable = (predicted_line[27:19] == 9'h038);
wire predicted_duplicate =
    (buffer_valid[0] && buffer_line0 == predicted_line) |
    (buffer_valid[1] && buffer_line1 == predicted_line) |
    (refill_busy && refill_line == predicted_line) |
    (candidate_valid_r && candidate_line_r == predicted_line);
wire candidate_eligible = predict_s1_valid && predicted_cacheable &&
                          ~predicted_duplicate;
wire candidate_push_empty = candidate_eligible & ~candidate_valid_r;
wire candidate_push_replace = candidate_eligible & candidate_valid_r &
                              candidate_take;

always @(posedge clk) begin
    if (reset) begin
        candidate_valid_r <= 1'b0;
    end else begin
        if (candidate_take)
            candidate_valid_r <= 1'b0;
        // 空 slot 上新生成的 candidate 可被 D-cache 当拍直接消费，无需
        // 再保存一份；若本拍同时消费旧 candidate，则把新项接替进去。
        if (candidate_push_replace |
            (candidate_push_empty & ~candidate_take)) begin
            candidate_valid_r <= 1'b1;
        end
        // payload 在 invalid 时是 don't-care：只要当前没有必须保留的旧项，
        // 就可登记 predicted_line。这样 payload CE 只依赖本地 valid/take，
        // 不再经过 predicted address、重复检查、pf_start 和 eligibility。
        // 真正的 valid 保存/替换仍由上面的 candidate_push_* 精确控制。
        if (~candidate_valid_r | candidate_take)
            candidate_line_r <= predicted_line;
    end
end

assign candidate_valid = candidate_valid_r | candidate_push_empty;
assign candidate_addr = candidate_valid_r ? {candidate_line_r, 4'b0}
                                           : {predicted_line, 4'b0};

endmodule

module dcache #(
    parameter integer IDX_BITS  = 7,
    parameter integer WORD_BITS = 2
) (
    input  wire        clk,
    input  wire        reset,

    input  wire        cpu_req,
    input  wire [ 3:0] cpu_we,
    input  wire [ 2:0] cpu_size,
    input  wire [31:0] cpu_addr,
    input  wire [31:0] cpu_wdata,
    input  wire [31:0] cpu_pc,
    input  wire        store_pending,
    output wire        cpu_addr_ok,
    output wire [31:0] cpu_rdata,
    output wire        cpu_data_ok,

    output wire        mem_rd_req,
    output wire [ 2:0] mem_rd_size,
    output wire [31:0] mem_rd_addr,
    input  wire [31:0] mem_rdata,
    input  wire        mem_rd_ok,

    output wire        mem_wr_req,
    output wire [ 2:0] mem_wr_size,
    output wire [31:0] mem_wr_addr,
    output wire [ 3:0] mem_wr_strb,
    output wire [31:0] mem_wr_data,
    input  wire        mem_wr_ok,

    output wire        inst_safe,
    output wire        perf_hit,
    output wire        perf_miss,
    output wire        perf_wb_stall
);

localparam integer NSETS    = (1 << IDX_BITS);
localparam integer WORDS    = (1 << WORD_BITS);
localparam integer OFF      = WORD_BITS + 2;
localparam integer TAG_BITS = 32 - IDX_BITS - OFF;
localparam integer DADDR    = IDX_BITS + WORD_BITS;

localparam [2:0] S_IDLE     = 3'd0;
localparam [2:0] S_LOOKUP   = 3'd1;
localparam [2:0] S_WAIT_WB  = 3'd2;
localparam [2:0] S_REFILL   = 3'd3;
localparam [2:0] S_RELOOKUP = 3'd4;
localparam [2:0] S_UNCACHED = 3'd5;
localparam [2:0] S_WAIT_PF  = 3'd6;
localparam [2:0] S_WORD_READ = 3'd7;

reg [2:0] state;

reg [31:0] req_addr;
reg [ 3:0] req_we;
reg [ 2:0] req_size;
reg [31:0] req_wdata;
reg [31:0] req_pc;
reg        req_trained;
reg        req_word_only;
reg        req_probe;

wire policy_query_word_only;
wire policy_query_probe;

wire req_store = |req_we;
wire req_cacheable = (req_addr[31:23] == 9'h038);

wire [IDX_BITS-1:0]  in_idx  = cpu_addr[OFF +: IDX_BITS];
wire [WORD_BITS-1:0] in_word = cpu_addr[2 +: WORD_BITS];
wire [IDX_BITS-1:0]  req_idx  = req_addr[OFF +: IDX_BITS];
wire [WORD_BITS-1:0] req_word = req_addr[2 +: WORD_BITS];
wire [TAG_BITS-1:0]  req_tag  = req_addr[32-TAG_BITS +: TAG_BITS];

// tag 只有 128x21b，使用 distributed RAM 可避免小数组浪费整块 BRAM，
// 也避免 AXI CDC 异步复位信号间接驱动 BRAM enable 的 REQP-1840 告警。
(* ram_style = "distributed" *) reg [TAG_BITS-1:0] tag0_mem [0:NSETS-1];
(* ram_style = "distributed" *) reg [TAG_BITS-1:0] tag1_mem [0:NSETS-1];
// data 每路 512x32b，正好填满一个 RAMB18，扩容不增加 BRAM 数量。
(* ram_style = "block" *) reg [31:0] data0_mem [0:NSETS*WORDS-1];
(* ram_style = "block" *) reg [31:0] data1_mem [0:NSETS*WORDS-1];
reg [NSETS-1:0] valid0, valid1, lru;

reg [TAG_BITS-1:0] tag0_q, tag1_q;
reg [31:0] data0_q, data1_q;
reg v0_q, v1_q, lru_q;

wire hit0 = v0_q & (tag0_q == req_tag);
wire hit1 = v1_q & (tag1_q == req_tag);
wire hit  = hit0 | hit1;

// ------------------------------ stream prefetch buffer -------------------
// Prefetch data stays outside the single-port cache BRAM, allowing normal
// cache hits while a speculative SRAM burst is in flight.
reg [1:0]  pf_valid;
reg [1:0]  pf_used;
reg [27:0] pf_line [0:1];
reg [31:0] pf_data [0:1][0:3];
reg        pf_busy;
reg        pf_slot;
reg        pf_rr;
reg [1:0]  pf_count;
reg [31:0] pf_active_addr;
reg        pf_poison;

// Stream-buffer lookup is performed from the incoming request and registered
// on the same edge as req_addr.  The old organization compared registered
// req_addr in S_LOOKUP and then drove both data_ok/ready and the complete
// EX2->RF forwarding mux in one cycle.  At high frequency that made pf_line
// fan out through the whole completion/backpressure chain.
//
// This retiming does not add a demand-hit cycle: a request is still accepted
// in cycle N and answered in S_LOOKUP in cycle N+1.  It only moves the
// stream-buffer tag/data selection into the existing request-capture boundary.
reg        pf_hit0_q;
reg        pf_hit1_q;
reg        pf_hit_unused_q;
reg [31:0] pf_hit_data_q;

wire pf_hit0 = pf_hit0_q;
wire pf_hit1 = pf_hit1_q;
wire pf_hit = pf_hit0 | pf_hit1;
wire pf_hit_slot = pf_hit1;
wire [31:0] pf_hit_data = pf_hit_data_q;
wire effective_hit = hit | pf_hit;
wire [31:0] hit_data = pf_hit ? pf_hit_data :
                         (hit0 ? data0_q : data1_q);

// 请求在 IDLE 被接受；连续 load hit 时，当前响应与下一个
// 地址接受可同拍发生。store hit 需要占用单口 data RAM 写口，
// 所以不在该拍继续接收。
wire cache_load_hit = (state == S_LOOKUP) & req_cacheable &
                      ~req_store & effective_hit;
assign cpu_addr_ok = (state == S_IDLE) | cache_load_hit;
wire cpu_accept = cpu_req & cpu_addr_ok;
wire incoming_pf_hit0 = pf_valid[0] &&
                        (pf_line[0] == cpu_addr[31:4]);
wire incoming_pf_hit1 = pf_valid[1] &&
                        (pf_line[1] == cpu_addr[31:4]);

// 接受请求的时钟沿同步读出 tag/data，LOOKUP 拍完成比较。
wire use_input = cpu_accept;
wire [IDX_BITS-1:0]  rd_idx  = use_input ? in_idx  : req_idx;
wire [WORD_BITS-1:0] rd_word = use_input ? in_word : req_word;
wire [DADDR-1:0]     rd_addr = {rd_idx, rd_word};

reg                  refill_way;
reg [WORD_BITS-1:0]  refill_cnt;
// Demand refill starts at the requested word and wraps inside the 16-byte
// line. refill_cnt is the returned-beat number, not the physical word index.
wire [WORD_BITS-1:0] refill_word = req_word + refill_cnt;
wire [DADDR-1:0] refill_addr = {req_idx, refill_word};
wire refill_fire = (state == S_REFILL) & mem_rd_ok;
wire refill_last = refill_fire & (refill_cnt == {WORD_BITS{1'b1}});
// 首个返回 beat 就是请求 word，先让流水继续；尾部三 beat 仍写完整行，
// 不重复产生 data_ok。
wire refill_critical = refill_fire &
                       (refill_cnt == {WORD_BITS{1'b0}});
wire victim_way = ~v0_q ? 1'b0 : ~v1_q ? 1'b1 : lru_q;

// ------------------------------ write buffer ------------------------------
wire        wb_enq_ready;
wire        wb_mem_req;
wire [31:0] wb_mem_addr;
wire [ 2:0] wb_mem_size;
wire [ 3:0] wb_mem_strb;
wire [31:0] wb_mem_data;
wire        wb_empty;
wire        wb_line_conflict;
wire        wb_prefetch_chip_conflict;
wire        pf_candidate_valid;
wire [31:0] pf_candidate_addr;

wire cache_store_finish = (state == S_LOOKUP) & req_cacheable & req_store &
                          wb_enq_ready;
wire uncached_store = (state == S_UNCACHED) & req_store;

write_buffer u_write_buffer (
    .clk       (clk),
    .reset     (reset),
    .enq_valid (cache_store_finish),
    .enq_ready (wb_enq_ready),
    .enq_addr  (req_addr),
    .enq_size  (req_size),
    .enq_strb  (req_we),
    .enq_data  (req_wdata),
    .mem_req   (wb_mem_req),
    .mem_addr  (wb_mem_addr),
    .mem_size  (wb_mem_size),
    .mem_strb  (wb_mem_strb),
    .mem_data  (wb_mem_data),
    .mem_done  (wb_mem_req & mem_wr_ok & ~uncached_store),
    .empty     (wb_empty),
    .query_addr(req_addr),
    .line_conflict(wb_line_conflict),
    .chip_query_addr(pf_candidate_addr),
    .chip_conflict(wb_prefetch_chip_conflict)
);

// ------------------------------ CPU response ------------------------------
wire uncached_done  = (state == S_UNCACHED) &
                      (req_store ? mem_wr_ok : mem_rd_ok);
wire word_read_done = (state == S_WORD_READ) & mem_rd_ok;

assign cpu_data_ok = cache_load_hit | cache_store_finish | uncached_done |
                     refill_critical | word_read_done;
assign cpu_rdata   = uncached_done    ? mem_rdata :
                     word_read_done   ? mem_rdata :
                     refill_critical  ? mem_rdata : hit_data;

assign perf_hit      = cache_load_hit;
assign perf_miss     = (state == S_LOOKUP) & req_cacheable &
                       ~req_store & ~effective_hit;
assign perf_wb_stall = (state == S_LOOKUP) & req_cacheable & req_store &
                       ~wb_enq_ready;

// EX1 中尚未发出的 store、以及已经接受但尚未进入写缓冲的 store 都必须
// 阻止新的 I-cache miss 越过。store_pending 只来自 EX1 寄存 payload，
// 不依赖 EX2 allow/data_addr_ok，避免 completion 反馈到下一 SRAM 请求。
// 否则自修改 flush 后可能在 store 真正对外可见前重填旧指令。
wire resident_store = (state != S_IDLE) & req_store;
assign inst_safe = wb_empty & ~store_pending & ~resident_store;

// ------------------------------ memory ports ------------------------------
wire refill_req      = (state == S_REFILL);
wire uncached_load   = (state == S_UNCACHED) & ~req_store;
wire word_read_req   = (state == S_WORD_READ);
wire demand_mem_rd_req = refill_req | uncached_load | word_read_req;

assign mem_rd_req  = demand_mem_rd_req | pf_busy;
assign mem_rd_size = demand_mem_rd_req ?
                     (refill_req ? 3'b100 : req_size) : 3'b100;
assign mem_rd_addr = demand_mem_rd_req ?
                     (refill_req ? {req_addr[31:2], 2'b0} : req_addr) :
                     pf_active_addr;

assign mem_wr_req  = uncached_store | wb_mem_req;
assign mem_wr_size = uncached_store ? req_size  : wb_mem_size;
assign mem_wr_addr = uncached_store ? req_addr  : wb_mem_addr;
assign mem_wr_strb = uncached_store ? req_we    : wb_mem_strb;
assign mem_wr_data = uncached_store ? req_wdata : wb_mem_data;

// ------------------------------ control FSM -------------------------------
always @(posedge clk) begin
    if (reset) begin
        state <= S_IDLE;
    end else begin
        case (state)
        S_IDLE:
            if (cpu_accept)
                state <= S_LOOKUP;
        S_LOOKUP:
            if (!req_cacheable)
                state <= wb_empty ? (pf_busy ? S_WAIT_PF : S_UNCACHED)
                                  : S_WAIT_WB;
            else if (req_store)
                state <= wb_enq_ready ? S_IDLE : S_LOOKUP;
            else if (effective_hit)
                state <= cpu_accept ? S_LOOKUP : S_IDLE;
            else if (pf_busy)
                state <= S_WAIT_PF;
            else
                state <= wb_line_conflict ? S_WAIT_WB :
                         (req_word_only ? S_WORD_READ : S_REFILL);
        S_WAIT_WB:
            if (req_cacheable ? ~wb_line_conflict : wb_empty)
                state <= pf_busy ? S_WAIT_PF :
                         (req_cacheable ?
                          (req_word_only ? S_WORD_READ : S_REFILL) :
                          S_UNCACHED);
        S_WAIT_PF:
            if (!pf_busy)
                state <= S_LOOKUP;
        S_REFILL:
            if (refill_last)
                // critical word 必然已在 4 beat 中返回，不再 relookup
                // 产生第二次 data_ok。
                state <= S_IDLE;
        S_RELOOKUP:
            state <= S_LOOKUP;
        S_UNCACHED:
            if (req_store ? mem_wr_ok : mem_rd_ok)
                state <= S_IDLE;
        S_WORD_READ:
            if (mem_rd_ok)
                state <= S_IDLE;
        default:
            state <= S_IDLE;
        endcase
    end
end

always @(posedge clk) begin
    if (cpu_accept) begin
        req_addr  <= cpu_addr;
        req_we    <= cpu_we;
        req_size  <= cpu_size;
        req_wdata <= cpu_wdata;
        req_pc    <= cpu_pc;
        req_word_only <= policy_query_word_only;
        req_probe <= policy_query_probe;
    end
end

always @(posedge clk) begin
    if (reset) begin
        pf_hit0_q       <= 1'b0;
        pf_hit1_q       <= 1'b0;
        pf_hit_unused_q <= 1'b0;
        pf_hit_data_q   <= 32'b0;
    end else if (cpu_accept) begin
        pf_hit0_q       <= incoming_pf_hit0;
        pf_hit1_q       <= incoming_pf_hit1;
        pf_hit_unused_q <= incoming_pf_hit0 ? ~pf_used[0] :
                           incoming_pf_hit1 ? ~pf_used[1] : 1'b0;
        pf_hit_data_q   <= incoming_pf_hit0 ? pf_data[0][in_word] :
                           incoming_pf_hit1 ? pf_data[1][in_word] : 32'b0;
    end
end

// ------------------------------ per-PC stride prefetcher -----------------
wire train_demand_miss = (state == S_LOOKUP) & req_cacheable &
                         ~req_store & ~effective_hit;
wire train_prefetch_hit = cache_load_hit & pf_hit &
                          pf_hit_unused_q;
wire predictor_train = ~req_trained &&
                       (train_demand_miss | train_prefetch_hit);

// query hint 已在 cpu_accept 沿锁存。这里只在请求真正离开 LOOKUP/WAIT_WB
// 开始单字服务或完整行 probe 时反馈，等待期间不会重复计数。
wire lookup_service_start = train_demand_miss && ~pf_busy &&
                            ~wb_line_conflict;
wire wait_service_start = (state == S_WAIT_WB) & req_cacheable &
                          ~wb_line_conflict & ~pf_busy;
wire policy_word_start = (lookup_service_start | wait_service_start) &
                         req_word_only;
wire policy_probe_start = (lookup_service_start | wait_service_start) &
                          req_probe;
wire policy_line_wait = (state == S_WAIT_WB) & req_cacheable &
                        req_word_only & wb_line_conflict;
wire policy_feedback_valid = cache_load_hit | policy_word_start |
                             policy_probe_start;
wire policy_feedback_hit = cache_load_hit;
wire policy_enter_event;
wire policy_exit_hit_event;
wire policy_exit_pattern_event;

// load->store-data 晚旁路会在当前 load hit 的同拍接收 store。其 LOOKUP
// 下一拍恰好也是 stride predictor 的下一个 candidate 到达的时刻；若只
// 允许 IDLE/load-hit 启动，顺序流的预取会晚一拍并退化为隔行 miss。
// 当前 store 与 candidate 位于不同 SRAM 芯片时，可在 store 入 WB 的
// 同拍启动预取；同片冲突仍由这里及 WB 的完整队列查询共同阻止。
wire completing_store_same_chip =
    cache_store_finish &&
    (req_addr[31:22] == pf_candidate_addr[31:22]);
wire pf_start_window = (state == S_IDLE) | cache_load_hit |
                       (cache_store_finish & ~completing_store_same_chip);
wire incoming_store_same_chip = cpu_accept && (|cpu_we) &&
                                (cpu_addr[31:22] ==
                                 pf_candidate_addr[31:22]);
// 若刚产生的 candidate 与同拍接受的 demand 是同一行，启动 prefetch
// 会让 demand 锁存到旧的 stream-buffer miss，burst 完成后又重复 refill。
// 只丢弃这条冗余 candidate；其余 candidate 仍保持当拍直通。
wire incoming_demand_same_line = cpu_accept && ~(|cpu_we) &&
                                 (cpu_addr[31:4] ==
                                  pf_candidate_addr[31:4]);
wire pf_candidate_drop = pf_candidate_valid &&
                         incoming_demand_same_line;
wire pf_start = pf_candidate_valid && ~pf_busy &&
                ~wb_prefetch_chip_conflict && pf_start_window &&
                ~incoming_store_same_chip &&
                ~incoming_demand_same_line &&
                ~(cpu_req && (cpu_addr[31:23] != 9'h038));
wire pf_refill_fire = pf_busy && mem_rd_ok;
wire pf_refill_last = pf_refill_fire & (pf_count == 2'b11);
wire pf_store_conflict = cache_store_finish &&
                         (req_addr[31:4] == pf_active_addr[31:4]);

dcache_prefetcher u_prefetcher (
    .clk            (clk),
    .reset          (reset),
    .train_valid    (predictor_train),
    .train_was_hit  (train_prefetch_hit),
    .train_pc       (req_pc),
    .train_addr     (req_addr),
    .query_valid    (cpu_accept),
    .query_pc       (cpu_pc),
    .query_word_only(policy_query_word_only),
    .query_probe    (policy_query_probe),
    .policy_feedback_valid(policy_feedback_valid),
    .policy_feedback_hit(policy_feedback_hit),
    .policy_feedback_probe(policy_probe_start),
    .policy_feedback_pc(req_pc),
    .buffer_valid   (pf_valid),
    .buffer_line0   (pf_line[0]),
    .buffer_line1   (pf_line[1]),
    .refill_busy    (pf_busy),
    .refill_line    (pf_active_addr[31:4]),
    .candidate_valid(pf_candidate_valid),
    .candidate_addr (pf_candidate_addr),
    .candidate_take (pf_start | pf_candidate_drop),
    .policy_enter_event(policy_enter_event),
    .policy_exit_hit_event(policy_exit_hit_event),
    .policy_exit_pattern_event(policy_exit_pattern_event)
);

always @(posedge clk) begin
    if (reset) begin
        req_trained <= 1'b0;
    end else if (cpu_accept) begin
        req_trained <= 1'b0;
    end else if (predictor_train) begin
        req_trained <= 1'b1;
    end
end

always @(posedge clk) begin
    if (reset) begin
        pf_valid <= 2'b0;
        pf_used <= 2'b0;
        pf_busy <= 1'b0;
        pf_slot <= 1'b0;
        pf_rr <= 1'b0;
        pf_count <= 2'b0;
        pf_poison <= 1'b0;
    end else begin
        if (cache_store_finish) begin
            if (pf_valid[0] && (pf_line[0] == req_addr[31:4]))
                pf_valid[0] <= 1'b0;
            if (pf_valid[1] && (pf_line[1] == req_addr[31:4]))
                pf_valid[1] <= 1'b0;
        end

        if (train_prefetch_hit)
            pf_used[pf_hit_slot] <= 1'b1;

        if (pf_start) begin
            pf_busy <= 1'b1;
            pf_count <= 2'b0;
            pf_active_addr <= pf_candidate_addr;
            pf_poison <= 1'b0;
            if (!pf_valid[0]) begin
                pf_slot <= 1'b0;
                pf_valid[0] <= 1'b0;
            end else if (!pf_valid[1]) begin
                pf_slot <= 1'b1;
                pf_valid[1] <= 1'b0;
            end else begin
                pf_slot <= pf_rr;
                pf_valid[pf_rr] <= 1'b0;
                pf_rr <= ~pf_rr;
            end
        end

        if (pf_busy && pf_store_conflict)
            pf_poison <= 1'b1;

        if (pf_refill_fire) begin
            pf_data[pf_slot][pf_count] <= mem_rdata;
            if (pf_refill_last) begin
                pf_busy <= 1'b0;
                if (!(pf_poison | pf_store_conflict)) begin
                    pf_line[pf_slot] <= pf_active_addr[31:4];
                    pf_valid[pf_slot] <= 1'b1;
                    pf_used[pf_slot] <= 1'b0;
                end
            end else begin
                pf_count <= pf_count + 1'b1;
            end
        end
    end
end

always @(posedge clk) begin
    if ((state == S_LOOKUP) & req_cacheable & ~req_store & ~hit) begin
        refill_way <= victim_way;
        refill_cnt <= '0;
    end else if ((state == S_WAIT_WB) & wb_empty & req_cacheable) begin
        refill_way <= victim_way;
        refill_cnt <= '0;
    end else if (refill_fire) begin
        refill_cnt <= refill_cnt + 1'b1;
    end
end

// ------------------------------ tag/data RAM ------------------------------
wire store_hit0 = cache_store_finish & hit0;
wire store_hit1 = cache_store_finish & hit1;
wire [DADDR-1:0] req_data_addr = {req_idx, req_word};
wire data0_we = (refill_fire & ~refill_way) | store_hit0;
wire data1_we = (refill_fire &  refill_way) | store_hit1;
wire [DADDR-1:0] data0_waddr = store_hit0 ? req_data_addr : refill_addr;
wire [DADDR-1:0] data1_waddr = store_hit1 ? req_data_addr : refill_addr;
wire [31:0] store_data0 = {
    req_we[3] ? req_wdata[31:24] : data0_q[31:24],
    req_we[2] ? req_wdata[23:16] : data0_q[23:16],
    req_we[1] ? req_wdata[15: 8] : data0_q[15: 8],
    req_we[0] ? req_wdata[ 7: 0] : data0_q[ 7: 0]
};
wire [31:0] store_data1 = {
    req_we[3] ? req_wdata[31:24] : data1_q[31:24],
    req_we[2] ? req_wdata[23:16] : data1_q[23:16],
    req_we[1] ? req_wdata[15: 8] : data1_q[15: 8],
    req_we[0] ? req_wdata[ 7: 0] : data1_q[ 7: 0]
};
wire [31:0] data0_wdata = store_hit0 ? store_data0 : mem_rdata;
wire [31:0] data1_wdata = store_hit1 ? store_data1 : mem_rdata;

always @(posedge clk) begin
    if (refill_fire & ~refill_way)
        tag0_mem[req_idx] <= req_tag;
    else
        tag0_q <= tag0_mem[rd_idx];
end

always @(posedge clk) begin
    if (refill_fire & refill_way)
        tag1_mem[req_idx] <= req_tag;
    else
        tag1_q <= tag1_mem[rd_idx];
end


always @(posedge clk) begin
    if (data0_we) begin
        // 用同步读出的旧 word 合并 byte strobe，再整 word 写回；这既保持
        // st.b 语义，也让 Vivado 能把 data array 推断成单口 BRAM。
        data0_mem[data0_waddr] <= data0_wdata;
    end else begin
        data0_q <= data0_mem[rd_addr];
    end
end

always @(posedge clk) begin
    if (data1_we) begin
        data1_mem[data1_waddr] <= data1_wdata;
    end else begin
        data1_q <= data1_mem[rd_addr];
    end
end

always @(posedge clk) begin
    v0_q  <= valid0[rd_idx];
    v1_q  <= valid1[rd_idx];
    lru_q <= lru[rd_idx];
end

always @(posedge clk) begin
    if (reset) begin
        valid0 <= '0;
        valid1 <= '0;
    end else if (refill_last) begin
        if (refill_way) valid1[req_idx] <= 1'b1;
        else            valid0[req_idx] <= 1'b1;
    end
end

always @(posedge clk) begin
    if (cache_load_hit | (cache_store_finish & hit))
        lru[req_idx] <= ~hit1;
    else if (refill_last)
        lru[req_idx] <= ~refill_way;
end

endmodule
