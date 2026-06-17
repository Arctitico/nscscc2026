// ============================================================================
// icache
// ============================================================================
module icache #(
    parameter integer IDX_BITS  = 6,   // 组数 = 2^IDX_BITS
    parameter integer WORD_BITS = 2    // 每行字数 = 2^WORD_BITS（默认 4 字 = 16B）
) (
    input  wire        clk,
    input  wire        reset,
    input  wire        flush,

    input  wire        req,
    input  wire [31:0] addr,
    output wire        addr_ok,
    output wire        data_ok,
    output wire [31:0] rdata,

    output wire        inst_rd_req,
    output wire [31:0] inst_rd_addr,    // 行基址（行内偏移清零）
    input  wire        inst_rd_rdy,     // 突发被接受
    input  wire        inst_ret_valid,  
    input  wire [31:0] inst_ret_data,
    input  wire        inst_ret_last
);

localparam integer NSETS      = (1 << IDX_BITS);
localparam integer WORDS      = (1 << WORD_BITS);
localparam integer OFF        = WORD_BITS + 2;        // 行内字节偏移位宽
localparam integer TAG_BITS   = 32 - IDX_BITS - OFF;
localparam integer DADDR_BITS = IDX_BITS + WORD_BITS; // 数据阵列字地址位宽

// 入参地址拆分
wire [IDX_BITS-1:0]   in_idx   = addr[OFF +: IDX_BITS];
wire [TAG_BITS-1:0]   in_tag   = addr[32-TAG_BITS +: TAG_BITS];
wire [WORD_BITS-1:0]  in_word  = addr[2 +: WORD_BITS];
wire [DADDR_BITS-1:0] in_daddr = addr[2 +: DADDR_BITS];   // = {in_idx, in_word}

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

// 接受一次新请求
wire accept = req & ~flush & ( (state==S_IDLE) | (in_lookup & hit) );

// 本拍读 RAM 的地址：接受新地址, 用入参; 否则（RELOOKUP）用缓冲 req
wire                  use_in   = accept;
wire [IDX_BITS-1:0]   rd_idx   = use_in ? in_idx   : req_idx;
wire [DADDR_BITS-1:0] rd_daddr = use_in ? in_daddr : {req_idx, req_word};

wire victim_way = ~v0_q ? 1'b0 : ~v1_q ? 1'b1 : lru_q;

assign addr_ok = accept;
assign data_ok = in_lookup & hit & ~flush;
assign rdata   = hit0 ? data0_q : data1_q;

assign inst_rd_req  = (state == S_REQ);
assign inst_rd_addr = {req_tag, req_idx, {OFF{1'b0}}};

wire refill_word = (state==S_FILL) & inst_ret_valid;
wire refill_last = refill_word & inst_ret_last;

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
    if (reset) begin
        rfl_way <= 1'b0;
        rfl_cnt <= '0;
    end else if (in_lookup & ~hit & ~flush) begin
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

// LRU
always @(posedge clk) begin
    if (reset)
        lru <= '0;
    else if (refill_last)
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
reg [31:0]         data0_mem[0:NSETS*WORDS-1];
reg [31:0]         data1_mem[0:NSETS*WORDS-1];
reg [31:0]         data0_q, data1_q;

reg [NSETS-1:0] valid0, valid1;

wire we0 = refill_word & (rfl_way == 1'b0);
wire we1 = refill_word & (rfl_way == 1'b1);

always @(posedge clk) begin
    if (we0) tag0_mem[req_idx] <= req_tag;
    else     tag0_q            <= tag0_mem[rd_idx];
end

always @(posedge clk) begin
    if (we0) data0_mem[{req_idx, rfl_cnt}] <= inst_ret_data;
    else     data0_q                       <= data0_mem[rd_daddr];
end

always @(posedge clk) begin
    if (we1) tag1_mem[req_idx] <= req_tag;
    else     tag1_q            <= tag1_mem[rd_idx];
end

always @(posedge clk) begin
    if (we1) data1_mem[{req_idx, rfl_cnt}] <= inst_ret_data;
    else     data1_q                       <= data1_mem[rd_daddr];
end

always @(posedge clk) begin
    if (reset) begin
        valid0 <= '0;
        valid1 <= '0;
    end else if (refill_last) begin
        if (rfl_way) valid1[req_idx] <= 1'b1;
        else         valid0[req_idx] <= 1'b1;
    end
end

always @(posedge clk) begin
    v0_q <= valid0[rd_idx];
    v1_q <= valid1[rd_idx];
end

endmodule
