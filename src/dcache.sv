// ============================================================================
// 透明数据 Cache（软件仍由 CPUCFG 看到“无 Cache”）
//
// - 4 KiB、2 路组相联、16B cache line，write-through/no-write-allocate。
// - BaseRAM/ExtRAM 0x1c000000-0x1c7fffff 可缓存；UART/其余地址旁路。
// - 普通 SRAM store 命中时更新 cache，同时进入两项 write buffer；miss 时
//   no-write-allocate，仍由两项 write buffer 写内存。
// - load miss 发起 4 beat 重填。外部 size=3'b100 是本核内部的“16B line”编码。
// - 指令 miss 只有在 write buffer 排空后才能发出，保证自修改代码可见。
// ============================================================================
module dcache_prefetcher (
    input  wire        clk,
    input  wire        reset,

    input  wire        train_valid,
    input  wire [31:0] train_pc,
    input  wire [31:0] train_addr,

    input  wire [ 1:0] buffer_valid,
    input  wire [27:0] buffer_line0,
    input  wire [27:0] buffer_line1,
    input  wire        refill_busy,
    input  wire [27:0] refill_line,

    output wire        candidate_valid,
    output wire [31:0] candidate_addr,
    input  wire        candidate_take
);

reg [7:0] pred_valid;
reg [26:0] pred_pc_tag [0:7];
reg [27:0] pred_last_line [0:7];
reg signed [27:0] pred_stride [0:7];
reg [1:0] pred_conf [0:7];

wire [2:0] pred_idx = train_pc[4:2];
wire [27:0] train_line = train_addr[31:4];
wire pred_match = pred_valid[pred_idx] &&
                  (pred_pc_tag[pred_idx] == train_pc[31:5]);
wire signed [27:0] observed_stride =
    $signed(train_line) - $signed(pred_last_line[pred_idx]);
wire stride_match = observed_stride == pred_stride[pred_idx];
wire [1:0] next_conf =
    stride_match ?
        (pred_conf[pred_idx] == 2'b11 ? 2'b11 :
                                             pred_conf[pred_idx] + 1'b1) :
        (pred_conf[pred_idx] == 2'b00 ? 2'b00 :
                                             pred_conf[pred_idx] - 1'b1);
wire signed [27:0] next_stride =
    (!stride_match && pred_conf[pred_idx] == 2'b00) ?
        observed_stride : pred_stride[pred_idx];

// Stage 1: finish table lookup, stride learning, and confidence update.
reg               predict_s1_valid;
reg [27:0]        predict_s1_line;
reg signed [27:0] predict_s1_stride;

always @(posedge clk) begin
    if (reset) begin
        pred_valid <= 8'b0;
        predict_s1_valid <= 1'b0;
    end else begin
        predict_s1_valid <= 1'b0;
        if (train_valid) begin
            if (!pred_match) begin
                pred_valid[pred_idx] <= 1'b1;
                pred_pc_tag[pred_idx] <= train_pc[31:5];
                pred_last_line[pred_idx] <= train_line;
                pred_stride[pred_idx] <= 28'sd0;
                pred_conf[pred_idx] <= 2'b00;
            end else begin
                pred_last_line[pred_idx] <= train_line;
                pred_stride[pred_idx] <= next_stride;
                pred_conf[pred_idx] <= next_conf;
                predict_s1_valid <= next_conf[1] && (next_stride != 0);
                predict_s1_line <= train_line;
                predict_s1_stride <= next_stride;
            end
        end
    end
end

    // Stage 2: add the predicted line, filter duplicates, and hold one
    // candidate until D-cache accepts it.
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
    wire candidate_slot_ready = ~candidate_valid_r | candidate_take;
    wire candidate_push = predict_s1_valid && predicted_cacheable &&
                          ~predicted_duplicate && candidate_slot_ready;

always @(posedge clk) begin
    if (reset) begin
        candidate_valid_r <= 1'b0;
    end else begin
            if (candidate_take)
                candidate_valid_r <= 1'b0;
            if (candidate_push) begin
                candidate_valid_r <= 1'b1;
                candidate_line_r <= predicted_line;
            end
        end
    end

assign candidate_valid = candidate_valid_r;
assign candidate_addr = {candidate_line_r, 4'b0};

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

reg [2:0] state;

reg [31:0] req_addr;
reg [ 3:0] req_we;
reg [ 2:0] req_size;
reg [31:0] req_wdata;
reg [31:0] req_pc;
reg        req_trained;

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
wire [DADDR-1:0] refill_addr = {req_idx, refill_cnt};
wire refill_fire = (state == S_REFILL) & mem_rd_ok;
wire refill_last = refill_fire & (refill_cnt == {WORD_BITS{1'b1}});
// 沿用 2025 D-cache 的 critical-word-first：请求 word 一返回就先让
// WB 继续，剩余 beat 仍在后台写完整行。WB 正在等待这次响应，
// 因而可按 SRAM 接口语义消费单拍 data_ok 脉冲。
wire refill_critical = refill_fire & (refill_cnt == req_word);
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

assign cpu_data_ok = cache_load_hit | cache_store_finish | uncached_done |
                     refill_critical;
assign cpu_rdata   = uncached_done    ? mem_rdata :
                     refill_critical  ? mem_rdata : hit_data;

assign perf_hit      = cache_load_hit;
assign perf_miss     = (state == S_LOOKUP) & req_cacheable &
                       ~req_store & ~effective_hit;
assign perf_wb_stall = (state == S_LOOKUP) & req_cacheable & req_store &
                       ~wb_enq_ready;

// 当前 EX store 尚未入队时也阻止新的 I-cache miss 越过它。
assign inst_safe = wb_empty & ~(cpu_req & (|cpu_we));

// ------------------------------ memory ports ------------------------------
wire refill_req      = (state == S_REFILL);
wire uncached_load   = (state == S_UNCACHED) & ~req_store;
wire demand_mem_rd_req = refill_req | uncached_load;

assign mem_rd_req  = demand_mem_rd_req | pf_busy;
assign mem_rd_size = demand_mem_rd_req ?
                     (refill_req ? 3'b100 : req_size) : 3'b100;
assign mem_rd_addr = demand_mem_rd_req ?
                     (refill_req ? {req_addr[31:OFF], {OFF{1'b0}}} : req_addr) :
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
                state <= wb_line_conflict ? S_WAIT_WB : S_REFILL;
        S_WAIT_WB:
            if (req_cacheable ? ~wb_line_conflict : wb_empty)
                state <= pf_busy ? S_WAIT_PF :
                         (req_cacheable ? S_REFILL : S_UNCACHED);
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

wire pf_start_window = (state == S_IDLE) | cache_load_hit;
wire incoming_store_same_chip = cpu_accept && (|cpu_we) &&
                                (cpu_addr[31:22] ==
                                 pf_candidate_addr[31:22]);
wire pf_start = pf_candidate_valid && ~pf_busy &&
                ~wb_prefetch_chip_conflict && pf_start_window &&
                ~incoming_store_same_chip &&
                ~(cpu_req && (cpu_addr[31:23] != 9'h038));
wire pf_refill_fire = pf_busy && mem_rd_ok;
wire pf_refill_last = pf_refill_fire & (pf_count == 2'b11);
wire pf_store_conflict = cache_store_finish &&
                         (req_addr[31:4] == pf_active_addr[31:4]);

dcache_prefetcher u_prefetcher (
    .clk            (clk),
    .reset          (reset),
    .train_valid    (predictor_train),
    .train_pc       (req_pc),
    .train_addr     (req_addr),
    .buffer_valid   (pf_valid),
    .buffer_line0   (pf_line[0]),
    .buffer_line1   (pf_line[1]),
    .refill_busy    (pf_busy),
    .refill_line    (pf_active_addr[31:4]),
    .candidate_valid(pf_candidate_valid),
    .candidate_addr (pf_candidate_addr),
    .candidate_take (pf_start)
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
