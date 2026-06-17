// ============================================================================
// mem_bridge —— CPU（取指突发读口 + 访存单字口）→ 板上 BaseRAM/ExtRAM/UART 桥
//
// 地址译码（按 addr[23:22]，与往届参考一致）：00=BaseRAM 01=ExtRAM 11=UART。
//   片内字地址 = addr[21:2]（每片 1M 字 = 4MB）。
//
// 取指口：**突发读通道**（icache 整行重填用）
//   inst_rd_req/inst_rd_addr(行基址) → inst_rd_rdy(被接受) / inst_ret_valid+
//   inst_ret_data+inst_ret_last(逐字回数，升序)。一次突发读 LINE_WORDS 个字。
// 访存口：单字「请求保持到 ok」，读/写，可达 UART。
//
// 仲裁：BaseRAM/ExtRAM 各一个独立 sram_ctrl，可并行（典型：取指走 Base ∥ 访存走 Ext）。
//   同片争用时**访存优先**（较老访存先走，取指属投机可等）；一旦某方被授予，sram_ctrl
//   busy 期间另一方等待（取指突发原子完成，不被访存打断）。tag(0=取指/1=访存)随 beat 带回。
//
// 三态：物理 inout 数据线在板级顶层 thinpad_top 处理。
// ============================================================================
module mem_bridge #(
    parameter integer SRAM_LATENCY = 2,
    parameter integer LINE_WORDS   = 4     // 取指突发字数（与 icache 行宽一致）
) (
    input  wire        clk,
    input  wire        reset,

    // ---- CPU 取指口（突发读；rd_req 保持到 rd_rdy）----
    input  wire        inst_rd_req,
    input  wire [31:0] inst_rd_addr,    // 行基址（低位对齐到行）
    output wire        inst_rd_rdy,     // 本拍突发被接受
    output wire        inst_ret_valid,  // 本拍返回一个字
    output wire [31:0] inst_ret_data,
    output wire        inst_ret_last,   // 突发最后一字

    // ---- CPU 访存口（req 保持到 data_ok）----
    input  wire        data_sram_en,
    input  wire [ 3:0] data_sram_we,
    input  wire [31:0] data_sram_addr,
    input  wire [31:0] data_sram_wdata,
    output wire [31:0] data_sram_rdata,
    output wire        data_ok,

    // ---- BaseRAM 物理侧（三态在顶层）----
    output wire [19:0] base_ram_addr,
    output wire [ 3:0] base_ram_be_n,
    output wire        base_ram_ce_n,
    output wire        base_ram_oe_n,
    output wire        base_ram_we_n,
    output wire [31:0] base_ram_wdat,
    input  wire [31:0] base_ram_rdat,

    // ---- ExtRAM 物理侧（三态在顶层）----
    output wire [19:0] ext_ram_addr,
    output wire [ 3:0] ext_ram_be_n,
    output wire        ext_ram_ce_n,
    output wire        ext_ram_oe_n,
    output wire        ext_ram_we_n,
    output wire [31:0] ext_ram_wdat,
    input  wire [31:0] ext_ram_rdat,

    // ---- 直连串口 ----
    output wire        txd,
    input  wire        rxd
);

localparam [2:0] INST_LEN = LINE_WORDS[2:0] - 3'd1;

// ---------------- 地址译码 ----------------
wire inst_base = inst_rd_req  & (inst_rd_addr[23:22]  == 2'b00);
wire inst_ext  = inst_rd_req  & (inst_rd_addr[23:22]  == 2'b01);
wire data_base = data_sram_en & (data_sram_addr[23:22] == 2'b00);
wire data_ext  = data_sram_en & (data_sram_addr[23:22] == 2'b01);
wire data_uart = data_sram_en & (data_sram_addr[23:22] == 2'b11);

// ================= BaseRAM 仲裁（访存优先；突发原子）=================
wire        base_busy;
wire        base_pick_data = data_base;                       // 访存优先
wire        base_req       = data_base | inst_base;
wire [19:0] base_acc_addr  = base_pick_data ? data_sram_addr[21:2] : inst_rd_addr[21:2];
wire [ 3:0] base_wstrb     = base_pick_data ? data_sram_we : 4'b0;
wire [ 2:0] base_len       = base_pick_data ? 3'd0 : INST_LEN;
wire        base_tagin     = base_pick_data ? 1'b1 : 1'b0;

wire        base_ok, base_beat_last, base_tagout;
wire [31:0] base_rdata;

sram_ctrl #(.LATENCY(SRAM_LATENCY)) u_base (
    .clk     (clk          ), .reset(reset),
    .ram_addr(base_ram_addr), .ram_be_n(base_ram_be_n),
    .ram_ce_n(base_ram_ce_n), .ram_oe_n(base_ram_oe_n), .ram_we_n(base_ram_we_n),
    .ram_wdat(base_ram_wdat), .ram_rdat(base_ram_rdat),
    .req     (base_req     ), .wstrb(base_wstrb), .addr(base_acc_addr),
    .wdata   (data_sram_wdata), .len(base_len), .tag_in(base_tagin),
    .ok      (base_ok      ), .rdata(base_rdata), .beat_last(base_beat_last),
    .tag_out (base_tagout  ), .busy(base_busy)
);

// 取指被授予 Base：本片空闲、取指要、且无访存抢占
wire base_grant_inst = ~base_busy & inst_base & ~data_base;
wire base_ret_inst   = base_ok & ~base_tagout;     // 取指 beat
wire base_ok_data    = base_ok &  base_tagout;     // 访存完成

// ================= ExtRAM 仲裁（访存优先；突发原子）=================
wire        ext_busy;
wire        ext_pick_data = data_ext;
wire        ext_req       = data_ext | inst_ext;
wire [19:0] ext_acc_addr  = ext_pick_data ? data_sram_addr[21:2] : inst_rd_addr[21:2];
wire [ 3:0] ext_wstrb     = ext_pick_data ? data_sram_we : 4'b0;
wire [ 2:0] ext_len       = ext_pick_data ? 3'd0 : INST_LEN;
wire        ext_tagin     = ext_pick_data ? 1'b1 : 1'b0;

wire        ext_ok, ext_beat_last, ext_tagout;
wire [31:0] ext_rdata;

sram_ctrl #(.LATENCY(SRAM_LATENCY)) u_ext (
    .clk     (clk         ), .reset(reset),
    .ram_addr(ext_ram_addr), .ram_be_n(ext_ram_be_n),
    .ram_ce_n(ext_ram_ce_n), .ram_oe_n(ext_ram_oe_n), .ram_we_n(ext_ram_we_n),
    .ram_wdat(ext_ram_wdat), .ram_rdat(ext_ram_rdat),
    .req     (ext_req     ), .wstrb(ext_wstrb), .addr(ext_acc_addr),
    .wdata   (data_sram_wdata), .len(ext_len), .tag_in(ext_tagin),
    .ok      (ext_ok      ), .rdata(ext_rdata), .beat_last(ext_beat_last),
    .tag_out (ext_tagout  ), .busy(ext_busy)
);

wire ext_grant_inst = ~ext_busy & inst_ext & ~data_ext;
wire ext_ret_inst   = ext_ok & ~ext_tagout;
wire ext_ok_data    = ext_ok &  ext_tagout;

// ---------------- UART（仅访存，单字）----------------
wire        uart_ok;
wire [31:0] uart_rdata;

uart_mm u_uart (
    .clk    (clk           ), .reset(reset),
    .txd    (txd           ), .rxd(rxd),
    .req    (data_uart     ), .wstrb(data_sram_we), .reg_sel(data_sram_addr[2]),
    .wdata  (data_sram_wdata), .tag_in(1'b1),
    .ok     (uart_ok       ), .rdata(uart_rdata), .tag_out()
);

// ---------------- 取指突发返回路由 ----------------
assign inst_rd_rdy    = base_grant_inst | ext_grant_inst;
assign inst_ret_valid = base_ret_inst | ext_ret_inst;
assign inst_ret_data  = base_ret_inst ? base_rdata : ext_rdata;
assign inst_ret_last  = (base_ret_inst & base_beat_last) | (ext_ret_inst & ext_beat_last);

// ---------------- 访存返回路由 ----------------
assign data_ok         = base_ok_data | ext_ok_data | uart_ok;
assign data_sram_rdata = base_ok_data ? base_rdata :
                         ext_ok_data  ? ext_rdata  : uart_rdata;

endmodule
