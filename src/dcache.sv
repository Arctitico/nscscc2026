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
import cpu_pkg::*;

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
    input  ex_wb_slot_t cpu_meta,
    output wire        cpu_addr_ok,
    output wire [31:0] cpu_rdata,
    output wire        cpu_data_ok,
    output ex_wb_slot_t cpu_resp_meta,

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

reg [2:0] state;

reg [31:0] req_addr;
reg [ 3:0] req_we;
reg [ 2:0] req_size;
reg [31:0] req_wdata;
ex_wb_slot_t req_meta;

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
wire [31:0] hit_data = hit0 ? data0_q : data1_q;

// 请求在 IDLE 被接受；连续 load hit 时，当前响应与下一个
// 地址接受可同拍发生。store hit 需要占用单口 data RAM 写口，
// 所以不在该拍继续接收。
wire cache_load_hit = (state == S_LOOKUP) & req_cacheable & ~req_store & hit;
assign cpu_addr_ok = (state == S_IDLE) | cache_load_hit;
wire cpu_accept = cpu_req & cpu_addr_ok;

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
    .line_conflict(wb_line_conflict)
);

// ------------------------------ CPU response ------------------------------
wire uncached_done  = (state == S_UNCACHED) &
                      (req_store ? mem_wr_ok : mem_rd_ok);

assign cpu_data_ok = cache_load_hit | cache_store_finish | uncached_done |
                     refill_critical;
assign cpu_rdata   = uncached_done    ? mem_rdata :
                     refill_critical  ? mem_rdata : hit_data;
assign cpu_resp_meta = req_meta;

assign perf_hit      = cache_load_hit;
assign perf_miss     = (state == S_LOOKUP) & req_cacheable & ~req_store & ~hit;
assign perf_wb_stall = (state == S_LOOKUP) & req_cacheable & req_store &
                       ~wb_enq_ready;

// 当前 EX store 尚未入队时也阻止新的 I-cache miss 越过它。
assign inst_safe = wb_empty & ~(cpu_req & (|cpu_we));

// ------------------------------ memory ports ------------------------------
wire refill_req      = (state == S_REFILL);
wire uncached_load   = (state == S_UNCACHED) & ~req_store;

assign mem_rd_req  = refill_req | uncached_load;
assign mem_rd_size = refill_req ? 3'b100 : req_size;
assign mem_rd_addr = refill_req ? {req_addr[31:OFF], {OFF{1'b0}}} : req_addr;

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
                state <= wb_empty ? S_UNCACHED : S_WAIT_WB;
            else if (req_store)
                state <= wb_enq_ready ? S_IDLE : S_LOOKUP;
            else if (hit)
                state <= cpu_accept ? S_LOOKUP : S_IDLE;
            else
                state <= wb_line_conflict ? S_WAIT_WB : S_REFILL;
        S_WAIT_WB:
            if (req_cacheable ? ~wb_line_conflict : wb_empty)
                state <= req_cacheable ? S_REFILL : S_UNCACHED;
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
        req_meta  <= cpu_meta;
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
