// ============================================================================
// icache：每路 data RAM 拆成奇/偶 bank，一拍读出对齐 8B 内的两条指令。
// ============================================================================
module icache #(
    parameter integer IDX_BITS  = 6,   // 组数 = 2^IDX_BITS
    parameter integer WORD_BITS = 2    // 每行字数 = 2^WORD_BITS（默认 4 字 = 16B）
) (
    input  wire        clk,
    input  wire        reset,
    input  wire        flush,
    // 自修改代码检测。store 真正被 D-cache 接受时，若目标行已经驻留、
    // 正在查询/重填，或本拍刚被取指口接受，则通知顶层执行一次全局重取。
    input  wire        store_valid,
    input  wire [31:0] store_addr,
    input  wire        invalidate_all,
    output wire        selfmod_hit,

    input  wire        req,
    input  wire [31:0] addr,
    output wire        addr_ok,
    output wire        data_ok,
    output wire [31:0] rdata_lo,
    output wire [31:0] rdata_hi,

    output wire        inst_rd_req,
    output wire [31:0] inst_rd_addr,    // 行基址（行内偏移清零）
    input  wire        inst_rd_rdy,     // 突发被接受
    input  wire        inst_ret_valid,  
    input  wire [31:0] inst_ret_data,
    input  wire        inst_ret_last,

    output wire        perf_miss
);

localparam integer NSETS    = (1 << IDX_BITS);
localparam integer WORDS    = (1 << WORD_BITS);
localparam integer OFF      = WORD_BITS + 2;
localparam integer TAG_BITS = 32 - IDX_BITS - OFF;
localparam integer HW       = WORD_BITS - 1;
localparam integer HADDR    = IDX_BITS + HW;
localparam integer NHALF    = NSETS << HW;

// 入参地址拆分
wire [IDX_BITS-1:0]  in_idx  = addr[OFF +: IDX_BITS];
wire [TAG_BITS-1:0]  in_tag  = addr[32-TAG_BITS +: TAG_BITS];
wire [WORD_BITS-1:0] in_word = addr[2 +: WORD_BITS];

// FSM
localparam [2:0] S_IDLE=3'd0, S_LOOKUP=3'd1, S_REQ=3'd2, S_FILL=3'd3, S_RELOOKUP=3'd4;
reg [2:0] state;

// 请求缓冲
reg [TAG_BITS-1:0]   req_tag;
reg [IDX_BITS-1:0]   req_idx;
reg [WORD_BITS-1:0]  req_word;

// 重填
reg                  rfl_way;
reg [WORD_BITS-1:0]  rfl_cnt;
reg                  refill_flushed;
reg                  refill_valid_q;
reg [31:0]           refill_data_q;
reg                  refill_last_q;

// LRU
reg [NSETS-1:0]      lru;
reg                  lru_q;

// icache 命中
wire in_lookup = (state == S_LOOKUP);
reg  [TAG_BITS-1:0] tag0_q, tag1_q;
reg                 v0_q, v1_q;
wire hit0 = v0_q & (tag0_q == req_tag);
wire hit1 = v1_q & (tag1_q == req_tag);
wire hit  = in_lookup & (hit0 | hit1);
assign perf_miss = in_lookup & ~hit & ~flush;

// 接受一次新请求
wire accept = req & ~flush & ( (state==S_IDLE) | (in_lookup & hit) );

// 这里故意不只看 valid。若 store 与尚未完成的请求/重填同一行，旧数据仍
// 可能在 store 生效前返回；同样需要让该重填自然排空但禁止最终置 valid。
// 比较结果只用于顶层事件寄存器及同 bundle 年轻槽的 valid，不进入 I-cache
// 命中、addr_ok 或外部 SRAM 请求控制路径。
wire [IDX_BITS-1:0] store_idx = store_addr[OFF +: IDX_BITS];
wire [TAG_BITS-1:0] store_tag = store_addr[32-TAG_BITS +: TAG_BITS];
wire store_resident = (valid0[store_idx] &&
                       (tag0_mem[store_idx] == store_tag)) |
                      (valid1[store_idx] &&
                       (tag1_mem[store_idx] == store_tag));
wire store_active = (state != S_IDLE) &&
                    (store_addr[31:OFF] == {req_tag, req_idx});
wire store_accepted_fetch = accept &&
                            (store_addr[31:OFF] == addr[31:OFF]);
assign selfmod_hit = store_valid &
                     (store_resident | store_active | store_accepted_fetch);

// 本拍读 RAM 的地址只由 cache 自身的同步状态决定。空闲或命中时预读入参
// 地址；若本拍没有真正 accept，读出的数据会被状态/valid 丢弃。这样避免
// 将整条流水线的 allow-in/flush 组合链直接接到 BRAM 地址选择端。
wire                  use_in     = (state == S_IDLE) | (in_lookup & hit);
wire [IDX_BITS-1:0]   rd_idx     = use_in ? in_idx : req_idx;
wire [WORD_BITS-1:0]  rd_word    = use_in ? in_word : req_word;
wire [HW-1:0]         rd_word_hi = rd_word[WORD_BITS-1:1];
wire [HADDR-1:0]      rd_haddr   = {rd_idx, rd_word_hi};

wire victim_way = ~v0_q ? 1'b0 : ~v1_q ? 1'b1 : lru_q;

assign addr_ok = accept;
assign data_ok = in_lookup & hit & ~flush;

assign inst_rd_req  = (state == S_REQ);
assign inst_rd_addr = {req_tag, req_idx, {OFF{1'b0}}};

// AXI CDC 的返回 valid 带异步复位，先在 CPU 时钟域登记一拍，再用于控制
// BRAM 写入。数据和 last 同步登记，连续返回时仍可保持每拍一个 beat。
always @(posedge clk) begin
    if (reset) refill_valid_q <= 1'b0;
    else       refill_valid_q <= inst_ret_valid;

    if (inst_ret_valid) begin
        refill_data_q <= inst_ret_data;
        refill_last_q <= inst_ret_last;
    end
end

wire refill_word = (state==S_FILL) & refill_valid_q;
wire refill_last = refill_word & refill_last_q;

// 状态机
always @(posedge clk) begin
    if (reset) begin
        state <= S_IDLE;
    end else begin
        case (state)
        S_IDLE:
            if (accept) state <= S_LOOKUP;
        S_LOOKUP:
            if (flush)    state <= S_IDLE;
            else if (hit) state <= accept ? S_LOOKUP : S_IDLE;
            else          state <= S_REQ;
        S_REQ:
            if (inst_rd_rdy) state <= S_FILL;
            else if (flush)  state <= S_IDLE;
        S_FILL:
            if (refill_last) state <= (flush | refill_flushed) ? S_IDLE : S_RELOOKUP;
        S_RELOOKUP:
            state <= (flush | refill_flushed) ? S_IDLE : S_LOOKUP;
        default: state <= S_IDLE;
        endcase
    end
end

always @(posedge clk) begin
    if (accept) begin
        req_tag  <= in_tag;
        req_idx  <= in_idx;
        req_word <= in_word;
    end
end

always @(posedge clk) begin
    if (in_lookup & ~hit & ~flush) begin
        rfl_way <= victim_way;
        rfl_cnt <= '0;
    end else if (refill_word) begin
        rfl_cnt <= rfl_cnt + 1'b1;
    end
end

// 重填期间遭遇 flush , 记录下来
always @(posedge clk) begin
    if (reset)                            refill_flushed <= 1'b0;
    else if (in_lookup & ~hit & ~flush)   refill_flushed <= 1'b0;
    else if ((state==S_REQ | state==S_FILL) & flush) refill_flushed <= 1'b1;
end

// LRU 只在有效行参与替换，复位后由 valid0/valid1 屏蔽其旧值。
always @(posedge clk) begin
    if (refill_last & ~refill_flushed & ~flush)
        lru[req_idx] <= ~rfl_way;
    else if (in_lookup & hit)
        lru[req_idx] <= ~hit1;
end

always @(posedge clk) begin
    lru_q <= lru[rd_idx];
end

// =========================== 存储阵列 ===========================
reg [TAG_BITS-1:0] tag0_mem [0:NSETS-1];
reg [TAG_BITS-1:0] tag1_mem [0:NSETS-1];
reg [31:0]         data0_even[0:NHALF-1];
reg [31:0]         data0_odd [0:NHALF-1];
reg [31:0]         data1_even[0:NHALF-1];
reg [31:0]         data1_odd [0:NHALF-1];
reg [31:0]         d0e_q, d0o_q, d1e_q, d1o_q;

reg [NSETS-1:0] valid0, valid1;

wire we0 = refill_word & (rfl_way == 1'b0);
wire we1 = refill_word & (rfl_way == 1'b1);
wire [HW-1:0]    rfl_hi   = rfl_cnt[WORD_BITS-1:1];
wire [HADDR-1:0] wr_haddr = {req_idx, rfl_hi};
wire we0e = we0 & ~rfl_cnt[0];
wire we0o = we0 &  rfl_cnt[0];
wire we1e = we1 & ~rfl_cnt[0];
wire we1o = we1 &  rfl_cnt[0];

always @(posedge clk) begin
    if (we0) tag0_mem[req_idx] <= req_tag;
    else     tag0_q            <= tag0_mem[rd_idx];
end

always @(posedge clk) begin
    if (we1) tag1_mem[req_idx] <= req_tag;
    else     tag1_q            <= tag1_mem[rd_idx];
end

always @(posedge clk) begin
    if (we0e) data0_even[wr_haddr] <= refill_data_q;
    else      d0e_q                <= data0_even[rd_haddr];
end

always @(posedge clk) begin
    if (we0o) data0_odd[wr_haddr] <= refill_data_q;
    else      d0o_q               <= data0_odd[rd_haddr];
end

always @(posedge clk) begin
    if (we1e) data1_even[wr_haddr] <= refill_data_q;
    else      d1e_q                <= data1_even[rd_haddr];
end

always @(posedge clk) begin
    if (we1o) data1_odd[wr_haddr] <= refill_data_q;
    else      d1o_q               <= data1_odd[rd_haddr];
end

assign rdata_lo = hit0 ? d0e_q : d1e_q;
assign rdata_hi = hit0 ? d0o_q : d1o_q;

always @(posedge clk) begin
    if (reset | invalidate_all) begin
        valid0 <= '0;
        valid1 <= '0;
    end else begin
        if (refill_last & ~refill_flushed & ~flush) begin
            if (rfl_way) valid1[req_idx] <= 1'b1;
            else         valid0[req_idx] <= 1'b1;
        end
    end
end

always @(posedge clk) begin
    v0_q <= valid0[rd_idx];
    v1_q <= valid1[rd_idx];
end

endmodule
