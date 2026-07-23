// ============================================================================
// 透明 non-blocking D-cache（软件仍由 CPUCFG 看到“无 Cache”）
//
// - 4 KiB、2 路组相联、16B line，write-through/no-write-allocate。
// - 一项真实 MSHR，含四项 tagged waiter：
//   * miss 在途时继续查询/命中其它 cache line（hit-under-miss）；
//   * 同 line secondary miss 合并；
//   * fill word 写入当拍直接 bypass 给 waiter，随后从 fill buffer 返回；
//   * 单口 data BRAM 仅在实际 refill/store 写拍占用端口。
// - 普通 SRAM store 进入两项 write buffer；uncached/UART 保持强顺序。
// ============================================================================
import cpu_pkg::*;

module dcache #(
    parameter integer IDX_BITS  = 7,
    parameter integer WORD_BITS = 2
) (
    input  wire          clk,
    input  wire          reset,
    input  wire          flush,
    input  rob_idx_t     recover_idx,
    input  rob_idx_t     rob_head_idx,

    input  wire          cpu_req,
    input  wire [ 3:0]   cpu_we,
    input  wire [ 2:0]   cpu_size,
    input  wire [31:0]   cpu_addr,
    input  wire [31:0]   cpu_wdata,
    input  ex_wb_slot_t  cpu_meta,
    output wire          cpu_addr_ok,
    output wire [31:0]   cpu_rdata,
    output wire          cpu_data_ok,
    output ex_wb_slot_t  cpu_resp_meta,

    output wire          mem_rd_req,
    output wire [ 2:0]   mem_rd_size,
    output wire [31:0]   mem_rd_addr,
    input  wire [31:0]   mem_rdata,
    input  wire          mem_rd_ok,

    output wire          mem_wr_req,
    output wire [ 2:0]   mem_wr_size,
    output wire [31:0]   mem_wr_addr,
    output wire [ 3:0]   mem_wr_strb,
    output wire [31:0]   mem_wr_data,
    input  wire          mem_wr_ok,

    output wire          inst_safe,
    output wire          perf_hit,
    output wire          perf_miss,
    output wire          perf_wb_stall,
    output wire          perf_hit_under_miss,
    output wire          perf_secondary_merge,
    output wire          perf_independent_miss_busy,
    output wire          perf_mshr_full_stall,
    output wire          perf_refill_tail
);

localparam integer NSETS    = (1 << IDX_BITS);
localparam integer WORDS    = (1 << WORD_BITS);
localparam integer OFF      = WORD_BITS + 2;
localparam integer TAG_BITS = 32 - IDX_BITS - OFF;
localparam integer DADDR    = IDX_BITS + WORD_BITS;
localparam integer WAITERS  = 4;

function automatic logic younger_than_recover(input rob_idx_t idx);
    logic [ROB_BITS:0] idx_age;
    logic [ROB_BITS:0] recover_age;
    idx_age = {1'b0, idx - rob_head_idx};
    recover_age = {1'b0, recover_idx - rob_head_idx};
    younger_than_recover = (idx_age > recover_age);
endfunction

// ------------------------------ cache arrays ------------------------------
(* ram_style = "distributed" *) reg [TAG_BITS-1:0] tag0_mem [0:NSETS-1];
(* ram_style = "distributed" *) reg [TAG_BITS-1:0] tag1_mem [0:NSETS-1];
(* ram_style = "block" *) reg [31:0] data0_mem [0:NSETS*WORDS-1];
(* ram_style = "block" *) reg [31:0] data1_mem [0:NSETS*WORDS-1];
reg [NSETS-1:0] valid0, valid1, lru;

reg [TAG_BITS-1:0] tag0_q, tag1_q;
reg [31:0] data0_q, data1_q;
reg v0_q, v1_q, lru_q;

// ------------------------------ lookup pipe -------------------------------
reg             lookup_valid;
reg [31:0]      lookup_addr;
reg [ 3:0]      lookup_we;
reg [ 2:0]      lookup_size;
reg [31:0]      lookup_wdata;
ex_wb_slot_t    lookup_meta;

wire lookup_store = |lookup_we;
wire lookup_cacheable = (lookup_addr[31:23] == 9'h038);
wire [IDX_BITS-1:0] lookup_idx = lookup_addr[OFF +: IDX_BITS];
wire [WORD_BITS-1:0] lookup_word = lookup_addr[2 +: WORD_BITS];
wire [TAG_BITS-1:0] lookup_tag =
    lookup_addr[32-TAG_BITS +: TAG_BITS];
wire lookup_hit0 = lookup_valid & v0_q & (tag0_q == lookup_tag);
wire lookup_hit1 = lookup_valid & v1_q & (tag1_q == lookup_tag);
wire lookup_hit  = lookup_hit0 | lookup_hit1;
wire [31:0] lookup_hit_data = lookup_hit0 ? data0_q : data1_q;

// ------------------------------ one MSHR -----------------------------------
reg              mshr_valid;
reg              mshr_refill_done;
reg              mshr_way;
reg [31:0]       mshr_addr;
reg [WORD_BITS-1:0] refill_cnt;
reg [WORDS-1:0]  fill_valid;
reg [31:0]       fill_data [0:WORDS-1];
reg              primary_returned;

reg [WAITERS-1:0] waiter_valid;
reg [WORD_BITS-1:0] waiter_word [0:WAITERS-1];
ex_wb_slot_t       waiter_meta [0:WAITERS-1];

wire        wb_enq_ready;
wire        wb_mem_req;
wire [31:0] wb_mem_addr;
wire [ 2:0] wb_mem_size;
wire [ 3:0] wb_mem_strb;
wire [31:0] wb_mem_data;
wire        wb_empty;
wire        wb_line_conflict;

reg             uncached_valid;
reg [31:0]      uncached_addr;
reg [ 3:0]      uncached_we;
reg [ 2:0]      uncached_size;
reg [31:0]      uncached_wdata;
ex_wb_slot_t    uncached_meta;
wire uncached_store_active = uncached_valid & (|uncached_we);
wire uncached_load_active  = uncached_valid & ~(|uncached_we);

wire [IDX_BITS-1:0] mshr_idx = mshr_addr[OFF +: IDX_BITS];
wire [TAG_BITS-1:0] mshr_tag =
    mshr_addr[32-TAG_BITS +: TAG_BITS];
wire [DADDR-1:0] refill_addr = {mshr_idx, refill_cnt};
wire refill_fire = mshr_valid & ~mshr_refill_done &
                   ~wb_line_conflict & mem_rd_ok;
wire refill_last = refill_fire & (refill_cnt == WORD_BITS'(WORDS-1));

logic waiter_free_found;
logic [1:0] waiter_free_idx;
always_comb begin
    waiter_free_found = 1'b0;
    waiter_free_idx = 2'd0;
    for (int unsigned i = 0; i < WAITERS; i++) begin
        if (!waiter_valid[i] && !waiter_free_found) begin
            waiter_free_found = 1'b1;
            waiter_free_idx = 2'(i);
        end
    end
end

logic waiter_ready_found;
logic [1:0] waiter_ready_idx;
logic [31:0] waiter_ready_data;
always_comb begin
    waiter_ready_found = 1'b0;
    waiter_ready_idx = 2'd0;
    waiter_ready_data = 32'b0;
    for (int unsigned i = 0; i < WAITERS; i++) begin
        if (waiter_valid[i] && !waiter_ready_found &&
            (fill_valid[waiter_word[i]] |
             (refill_fire && (refill_cnt == waiter_word[i])))) begin
            waiter_ready_found = 1'b1;
            waiter_ready_idx = 2'(i);
            waiter_ready_data =
                (refill_fire && (refill_cnt == waiter_word[i]))
                ? mem_rdata : fill_data[waiter_word[i]];
        end
    end
end

wire lookup_same_mshr = mshr_valid &&
    (lookup_addr[31:OFF] == mshr_addr[31:OFF]);
wire input_cacheable_load = (cpu_addr[31:23] == 9'h038) &&
                            (cpu_we == 4'b0);
wire input_same_mshr = mshr_valid &&
    (cpu_addr[31:OFF] == mshr_addr[31:OFF]);

// ------------------------------ write buffer ------------------------------
wire lookup_store_finish = lookup_valid & lookup_cacheable & lookup_store &
                           wb_enq_ready;

write_buffer u_write_buffer (
    .clk       (clk),
    .reset     (reset),
    .enq_valid (lookup_store_finish),
    .enq_ready (wb_enq_ready),
    .enq_addr  (lookup_addr),
    .enq_size  (lookup_size),
    .enq_strb  (lookup_we),
    .enq_data  (lookup_wdata),
    .mem_req   (wb_mem_req),
    .mem_addr  (wb_mem_addr),
    .mem_size  (wb_mem_size),
    .mem_strb  (wb_mem_strb),
    .mem_data  (wb_mem_data),
    .mem_done  (wb_mem_req & mem_wr_ok & ~uncached_store_active),
    .empty     (wb_empty),
    .query_addr(mshr_valid ? mshr_addr : lookup_addr),
    .line_conflict(wb_line_conflict)
);

// ------------------------------ uncached ----------------------------------
wire uncached_done = uncached_valid &
                     (uncached_store_active ? mem_wr_ok : mem_rd_ok);

// ------------------------------ lookup actions ----------------------------
wire lookup_load_hit = lookup_valid & lookup_cacheable &
                       ~lookup_store & lookup_hit;
wire lookup_load_miss = lookup_valid & lookup_cacheable &
                        ~lookup_store & ~lookup_hit;
wire lookup_primary_miss = lookup_load_miss & ~mshr_valid &
                           waiter_free_found;
wire lookup_secondary = lookup_load_miss & lookup_same_mshr &
                        waiter_free_found;
wire lookup_independent_busy = lookup_load_miss & mshr_valid &
                               ~lookup_same_mshr;
wire lookup_to_uncached = lookup_valid & ~lookup_cacheable &
                          ~mshr_valid & wb_empty & ~uncached_valid;

wire lookup_immediate_resp = lookup_load_hit | lookup_store_finish;
wire lookup_consumed = lookup_immediate_resp | lookup_primary_miss |
                       lookup_secondary | lookup_to_uncached;

// lookup miss 分配/合并与输入直达合并每拍最多一个 waiter enqueue。
wire direct_merge_ready = cpu_req & input_cacheable_load &
                          input_same_mshr & ~lookup_valid &
                          waiter_free_found;
wire waiter_enq = lookup_primary_miss | lookup_secondary |
                  (cpu_req & direct_merge_ready);
wire [WORD_BITS-1:0] waiter_enq_word =
    lookup_primary_miss | lookup_secondary ? lookup_word
                                           : cpu_addr[2 +: WORD_BITS];
ex_wb_slot_t waiter_enq_meta;
assign waiter_enq_meta =
    lookup_primary_miss | lookup_secondary ? lookup_meta : cpu_meta;

// ------------------------------ CPU request accept ------------------------
// refill 写拍占用单口 data BRAM；同 line merge 不读 BRAM，仍可接受。
wire lookup_slot_ready = ~lookup_valid | lookup_consumed;
wire normal_accept_ready = lookup_slot_ready & ~refill_fire &
                           ~lookup_store_finish &
                           ~uncached_valid &
                           // store/uncached 在 MSHR 排空前保持强顺序；
                           // cacheable load 可进入 lookup 做 hit-under-miss。
                           ((!mshr_valid) | input_cacheable_load);
assign cpu_addr_ok = direct_merge_ready |
                     (cpu_req & normal_accept_ready);
wire cpu_accept = cpu_req & cpu_addr_ok;
wire direct_merge_accept = cpu_accept & direct_merge_ready;
wire lookup_accept = cpu_accept & ~direct_merge_ready;

// ------------------------------ CPU response ------------------------------
// cache hit/store 先于 ready waiter，避免同步 lookup 结果额外滞留。
wire waiter_resp = waiter_ready_found & ~lookup_immediate_resp &
                   ~uncached_done;
wire response_raw_valid = lookup_immediate_resp | uncached_done | waiter_resp;
ex_wb_slot_t response_meta;
assign response_meta = lookup_immediate_resp ? lookup_meta :
                       uncached_done          ? uncached_meta :
                                                waiter_meta[waiter_ready_idx];
wire response_squashed = flush &&
                         younger_than_recover(response_meta.rob_idx);
assign cpu_data_ok = response_raw_valid & ~response_squashed;
assign cpu_rdata = lookup_load_hit ? lookup_hit_data :
                   uncached_done   ? mem_rdata :
                                     waiter_ready_data;
assign cpu_resp_meta = response_meta;

// ------------------------------ memory ports ------------------------------
wire mshr_read_active = mshr_valid & ~mshr_refill_done &
                        ~wb_line_conflict;
assign mem_rd_req  = mshr_read_active | uncached_load_active;
assign mem_rd_size = mshr_read_active ? 3'b100 : uncached_size;
assign mem_rd_addr = mshr_read_active
                   ? {mshr_addr[31:OFF], {OFF{1'b0}}}
                   : uncached_addr;

assign mem_wr_req  = uncached_store_active | wb_mem_req;
assign mem_wr_size = uncached_store_active ? uncached_size  : wb_mem_size;
assign mem_wr_addr = uncached_store_active ? uncached_addr  : wb_mem_addr;
assign mem_wr_strb = uncached_store_active ? uncached_we    : wb_mem_strb;
assign mem_wr_data = uncached_store_active ? uncached_wdata : wb_mem_data;

// 当前 EX store 尚未进入 lookup/write buffer 时也阻止 I-cache miss 越过。
assign inst_safe = wb_empty & ~uncached_valid &
                   ~(cpu_req & (|cpu_we)) &
                   ~(lookup_valid & lookup_store);

// ------------------------------ event counters ----------------------------
assign perf_hit = lookup_load_hit;
assign perf_miss = lookup_primary_miss;
assign perf_wb_stall = lookup_valid & lookup_cacheable & lookup_store &
                       ~wb_enq_ready;
assign perf_hit_under_miss = lookup_load_hit & mshr_valid;
assign perf_secondary_merge = lookup_secondary | direct_merge_accept;
assign perf_independent_miss_busy = lookup_independent_busy;
assign perf_mshr_full_stall = cpu_req & input_cacheable_load &
                              input_same_mshr & ~waiter_free_found;
assign perf_refill_tail = refill_fire & primary_returned;

// ------------------------------ state updates -----------------------------
always_ff @(posedge clk) begin
    if (reset) begin
        lookup_valid <= 1'b0;
    end else begin
        if (lookup_consumed ||
            (flush && lookup_valid &&
             younger_than_recover(lookup_meta.rob_idx)))
            lookup_valid <= 1'b0;
        if (lookup_accept) begin
            lookup_valid <= 1'b1;
            lookup_addr  <= cpu_addr;
            lookup_we    <= cpu_we;
            lookup_size  <= cpu_size;
            lookup_wdata <= cpu_wdata;
            lookup_meta  <= cpu_meta;
        end
    end
end

always_ff @(posedge clk) begin
    if (reset) begin
        uncached_valid <= 1'b0;
    end else begin
        if (uncached_done)
            uncached_valid <= 1'b0;
        if (lookup_to_uncached) begin
            uncached_valid <= 1'b1;
            uncached_addr  <= lookup_addr;
            uncached_we    <= lookup_we;
            uncached_size  <= lookup_size;
            uncached_wdata <= lookup_wdata;
            uncached_meta  <= lookup_meta;
        end
    end
end

always_ff @(posedge clk) begin
    if (reset) begin
        mshr_valid         <= 1'b0;
        mshr_refill_done   <= 1'b0;
        refill_cnt        <= '0;
        fill_valid        <= '0;
        primary_returned  <= 1'b0;
    end else begin
        if (lookup_primary_miss) begin
            mshr_valid        <= 1'b1;
            mshr_refill_done  <= 1'b0;
            mshr_way          <= ~v0_q ? 1'b0 : ~v1_q ? 1'b1 : lru_q;
            mshr_addr         <= lookup_addr;
            refill_cnt       <= '0;
            fill_valid       <= '0;
            primary_returned <= 1'b0;
        end else if (mshr_valid) begin
            if (refill_fire) begin
                fill_valid[refill_cnt] <= 1'b1;
                fill_data[refill_cnt]  <= mem_rdata;
                refill_cnt <= refill_cnt + 1'b1;
                if (refill_last)
                    mshr_refill_done <= 1'b1;
            end
            if (waiter_resp &&
                (waiter_ready_idx == 2'd0))
                primary_returned <= 1'b1;
            if (mshr_refill_done &&
                ((waiter_valid == '0) |
                 ((waiter_valid == (WAITERS'(1) << waiter_ready_idx)) &&
                  waiter_resp))) begin
                mshr_valid <= 1'b0;
                mshr_refill_done <= 1'b0;
                fill_valid <= '0;
            end
        end
    end
end

always_ff @(posedge clk) begin
    if (reset) begin
        waiter_valid <= '0;
    end else begin
        if (waiter_resp)
            waiter_valid[waiter_ready_idx] <= 1'b0;
        if (flush) begin
            for (int unsigned i = 0; i < WAITERS; i++) begin
                if (waiter_valid[i] &&
                    younger_than_recover(waiter_meta[i].rob_idx))
                    waiter_valid[i] <= 1'b0;
            end
        end
        if (waiter_enq) begin
            waiter_valid[waiter_free_idx] <= 1'b1;
            waiter_word[waiter_free_idx]  <= waiter_enq_word;
            waiter_meta[waiter_free_idx]  <= waiter_enq_meta;
        end
    end
end

// ------------------------------ RAM arbitration ---------------------------
wire [IDX_BITS-1:0] input_idx = cpu_addr[OFF +: IDX_BITS];
wire [WORD_BITS-1:0] input_word = cpu_addr[2 +: WORD_BITS];
wire [DADDR-1:0] lookup_read_addr = {input_idx, input_word};

wire store_hit0 = lookup_store_finish & lookup_hit0;
wire store_hit1 = lookup_store_finish & lookup_hit1;
wire [DADDR-1:0] lookup_data_addr = {lookup_idx, lookup_word};
wire data0_we = (refill_fire & ~mshr_way) | store_hit0;
wire data1_we = (refill_fire &  mshr_way) | store_hit1;
wire [DADDR-1:0] data0_waddr =
    store_hit0 ? lookup_data_addr : refill_addr;
wire [DADDR-1:0] data1_waddr =
    store_hit1 ? lookup_data_addr : refill_addr;
wire [31:0] store_data0 = {
    lookup_we[3] ? lookup_wdata[31:24] : data0_q[31:24],
    lookup_we[2] ? lookup_wdata[23:16] : data0_q[23:16],
    lookup_we[1] ? lookup_wdata[15: 8] : data0_q[15: 8],
    lookup_we[0] ? lookup_wdata[ 7: 0] : data0_q[ 7: 0]
};
wire [31:0] store_data1 = {
    lookup_we[3] ? lookup_wdata[31:24] : data1_q[31:24],
    lookup_we[2] ? lookup_wdata[23:16] : data1_q[23:16],
    lookup_we[1] ? lookup_wdata[15: 8] : data1_q[15: 8],
    lookup_we[0] ? lookup_wdata[ 7: 0] : data1_q[ 7: 0]
};

always_ff @(posedge clk) begin
    if (refill_fire & ~mshr_way)
        tag0_mem[mshr_idx] <= mshr_tag;
    else if (lookup_accept)
        tag0_q <= tag0_mem[input_idx];
end

always_ff @(posedge clk) begin
    if (refill_fire & mshr_way)
        tag1_mem[mshr_idx] <= mshr_tag;
    else if (lookup_accept)
        tag1_q <= tag1_mem[input_idx];
end

always_ff @(posedge clk) begin
    if (data0_we)
        data0_mem[data0_waddr] <= store_hit0 ? store_data0 : mem_rdata;
    else if (lookup_accept)
        data0_q <= data0_mem[lookup_read_addr];
end

always_ff @(posedge clk) begin
    if (data1_we)
        data1_mem[data1_waddr] <= store_hit1 ? store_data1 : mem_rdata;
    else if (lookup_accept)
        data1_q <= data1_mem[lookup_read_addr];
end

always_ff @(posedge clk) begin
    if (lookup_accept) begin
        v0_q  <= valid0[input_idx];
        v1_q  <= valid1[input_idx];
        lru_q <= lru[input_idx];
    end
end

always_ff @(posedge clk) begin
    if (reset) begin
        valid0 <= '0;
        valid1 <= '0;
    end else begin
        // victim 在首个 fill 写入前即失效，避免 hit-under-miss 读到
        // 已被部分覆盖的旧 cache line。
        if (lookup_primary_miss) begin
            if (~v0_q ? 1'b0 : ~v1_q ? 1'b1 : lru_q)
                valid1[lookup_idx] <= 1'b0;
            else
                valid0[lookup_idx] <= 1'b0;
        end
        if (refill_last) begin
            if (mshr_way)
                valid1[mshr_idx] <= 1'b1;
            else
                valid0[mshr_idx] <= 1'b1;
        end
    end
end

always_ff @(posedge clk) begin
    if (lookup_load_hit | (lookup_store_finish & lookup_hit))
        lru[lookup_idx] <= ~lookup_hit1;
    else if (refill_last)
        lru[mshr_idx] <= ~mshr_way;
end

endmodule
