// ============================================================================
// mem_bridge —— CPU（取指突发读口 + 访存读写口）→ 板上 BaseRAM/ExtRAM/UART 桥
//
// 2026 物理地址译码：
//   0x1c000000-0x1c3fffff = BaseRAM，0x1c400000-0x1c7fffff = ExtRAM；
//   0x1f000000-0x1f0fffff = UART 窗口。RAM 片内字地址 = addr[21:2]。
// 必须检查完整高位，不能仅看 addr[23:22] 而产生旧地址镜像。
//
// 取指口：**突发读通道**（icache 整行重填用）
//   inst_rd_req/inst_rd_addr(行基址) → inst_rd_rdy(被接受) / inst_ret_valid+
//   inst_ret_data+inst_ret_last(逐字回数，升序)。一次突发读 LINE_WORDS 个字。
// 访存口：「请求保持到 ok」，读/写，可达 UART；data_rd_size=3'b100 表示
//   四字 D-cache line burst，其余读写为单字。
//
// 仲裁：BaseRAM/ExtRAM 各一个独立 sram_ctrl，可并行（典型：取指走 Base ∥ 访存走 Ext）。
//   同片争用时**访存优先**（较老访存先走，取指属投机可等）；一旦某方被授予，sram_ctrl
//   busy 期间另一方等待（取指突发原子完成，不被访存打断）。tag(0=取指/1=访存)随 beat 带回。
//
// 三态：物理 inout 数据线在板级顶层 thinpad_top 处理。
// ============================================================================
module mem_bridge #(
    parameter integer SRAM_READ_CYCLES = 3,
    parameter integer SRAM_WRITE_CYCLES = 3,
    parameter integer SRAM_WRITE_HOLD_CYCLES = 1,
    parameter integer LINE_WORDS   = 4,    // 取指突发字数（与 icache 行宽一致）
    parameter integer CLK_FREQ     = 50_000_000
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

    // ---- CPU 数据读写口（各自保持到对应 ok）----
    input  wire        data_rd_req,
    input  wire [ 2:0] data_rd_size,
    input  wire [31:0] data_rd_addr,
    output wire [31:0] data_rd_data,
    output wire        data_rd_ok,
    input  wire        data_wr_req,
    input  wire [ 2:0] data_wr_size,
    input  wire [31:0] data_wr_addr,
    input  wire [ 3:0] data_wr_strb,
    input  wire [31:0] data_wr_data,
    output wire        data_wr_ok,

    // ---- BaseRAM 物理侧（三态在顶层）----
    output wire [19:0] base_ram_addr,
    output wire [ 3:0] base_ram_be_n,
    output wire        base_ram_ce_n,
    output wire        base_ram_oe_n,
    output wire        base_ram_we_n,
    output wire        base_ram_wdrive,
    output wire [31:0] base_ram_wdat,
    input  wire [31:0] base_ram_rdat,

    // ---- ExtRAM 物理侧（三态在顶层）----
    output wire [19:0] ext_ram_addr,
    output wire [ 3:0] ext_ram_be_n,
    output wire        ext_ram_ce_n,
    output wire        ext_ram_oe_n,
    output wire        ext_ram_we_n,
    output wire        ext_ram_wdrive,
    output wire [31:0] ext_ram_wdat,
    input  wire [31:0] ext_ram_rdat,

    // ---- 直连串口 ----
    output wire        txd,
    input  wire        rxd
);

localparam [2:0] INST_LEN = LINE_WORDS[2:0] - 3'd1;

// ---------------- 地址译码 ----------------
wire inst_base = inst_rd_req  & (inst_rd_addr[31:22]  == 10'h070);
wire inst_ext  = inst_rd_req  & (inst_rd_addr[31:22]  == 10'h071);
wire rd_base = data_rd_req & (data_rd_addr[31:22] == 10'h070);
wire rd_ext  = data_rd_req & (data_rd_addr[31:22] == 10'h071);
wire rd_uart = data_rd_req & (data_rd_addr[31:20] == 12'h1f0);
wire wr_base = data_wr_req & (data_wr_addr[31:22] == 10'h070);
wire wr_ext  = data_wr_req & (data_wr_addr[31:22] == 10'h071);
wire wr_uart = data_wr_req & (data_wr_addr[31:20] == 12'h1f0);

// ================= BaseRAM 仲裁（访存优先；突发原子）=================
wire        base_busy;
wire        base_pick_data = wr_base | rd_base;
wire        base_pick_write= wr_base;
wire        base_req       = base_pick_data | inst_base;
wire [19:0] base_acc_addr  = base_pick_data ?
                             (base_pick_write ? data_wr_addr[21:2] : data_rd_addr[21:2]) :
                             inst_rd_addr[21:2];
wire [ 3:0] base_wstrb     = base_pick_write ? data_wr_strb : 4'b0;
wire [ 2:0] base_len       = base_pick_data ?
                             ((!base_pick_write && data_rd_size == 3'b100) ? INST_LEN : 3'd0) :
                             INST_LEN;
wire        base_tagin     = base_pick_data ? 1'b1 : 1'b0;

wire        base_ok, base_beat_last, base_tagout;
wire [31:0] base_rdata;

sram_ctrl #(
    .READ_CYCLES(SRAM_READ_CYCLES),
    .WRITE_CYCLES(SRAM_WRITE_CYCLES),
    .WRITE_HOLD_CYCLES(SRAM_WRITE_HOLD_CYCLES)
) u_base (
    .clk     (clk          ), .reset(reset),
    .ram_addr(base_ram_addr), .ram_be_n(base_ram_be_n),
    .ram_ce_n(base_ram_ce_n), .ram_oe_n(base_ram_oe_n), .ram_we_n(base_ram_we_n),
    .ram_wdrive(base_ram_wdrive),
    .ram_wdat(base_ram_wdat), .ram_rdat(base_ram_rdat),
    .req     (base_req     ), .wstrb(base_wstrb), .addr(base_acc_addr),
    .wdata   (data_wr_data), .len(base_len), .tag_in(base_tagin),
    .ok      (base_ok      ), .rdata(base_rdata), .beat_last(base_beat_last),
    .tag_out (base_tagout  ), .busy(base_busy)
);

// 取指被授予 Base：本片空闲、取指要、且无访存抢占
wire base_grant_inst = ~base_busy & inst_base & ~base_pick_data;
wire base_ret_inst   = base_ok & ~base_tagout;     // 取指 beat
wire base_ok_data    = base_ok &  base_tagout;     // 访存完成
reg base_data_is_write;
always @(posedge clk) begin
    if (~base_busy & base_pick_data)
        base_data_is_write <= base_pick_write;
end

// ================= ExtRAM 仲裁（访存优先；突发原子）=================
wire        ext_busy;
wire        ext_pick_data = wr_ext | rd_ext;
wire        ext_pick_write= wr_ext;
wire        ext_req       = ext_pick_data | inst_ext;
wire [19:0] ext_acc_addr  = ext_pick_data ?
                            (ext_pick_write ? data_wr_addr[21:2] : data_rd_addr[21:2]) :
                            inst_rd_addr[21:2];
wire [ 3:0] ext_wstrb     = ext_pick_write ? data_wr_strb : 4'b0;
wire [ 2:0] ext_len       = ext_pick_data ?
                            ((!ext_pick_write && data_rd_size == 3'b100) ? INST_LEN : 3'd0) :
                            INST_LEN;
wire        ext_tagin     = ext_pick_data ? 1'b1 : 1'b0;

wire        ext_ok, ext_beat_last, ext_tagout;
wire [31:0] ext_rdata;

sram_ctrl #(
    .READ_CYCLES(SRAM_READ_CYCLES),
    .WRITE_CYCLES(SRAM_WRITE_CYCLES),
    .WRITE_HOLD_CYCLES(SRAM_WRITE_HOLD_CYCLES)
) u_ext (
    .clk     (clk         ), .reset(reset),
    .ram_addr(ext_ram_addr), .ram_be_n(ext_ram_be_n),
    .ram_ce_n(ext_ram_ce_n), .ram_oe_n(ext_ram_oe_n), .ram_we_n(ext_ram_we_n),
    .ram_wdrive(ext_ram_wdrive),
    .ram_wdat(ext_ram_wdat), .ram_rdat(ext_ram_rdat),
    .req     (ext_req     ), .wstrb(ext_wstrb), .addr(ext_acc_addr),
    .wdata   (data_wr_data), .len(ext_len), .tag_in(ext_tagin),
    .ok      (ext_ok      ), .rdata(ext_rdata), .beat_last(ext_beat_last),
    .tag_out (ext_tagout  ), .busy(ext_busy)
);

wire ext_grant_inst = ~ext_busy & inst_ext & ~ext_pick_data;
wire ext_ret_inst   = ext_ok & ~ext_tagout;
wire ext_ok_data    = ext_ok &  ext_tagout;
reg ext_data_is_write;
always @(posedge clk) begin
    if (~ext_busy & ext_pick_data)
        ext_data_is_write <= ext_pick_write;
end

// ---------------- UART（仅访存，单字）----------------
wire        uart_ok;
wire [31:0] uart_rdata;
wire        uart_pick_write = wr_uart;
wire        uart_req = wr_uart | rd_uart;
wire        uart_tagout;

uart_mm #(.CLK_FREQ(CLK_FREQ)) u_uart (
    .clk    (clk           ), .reset(reset),
    .txd    (txd           ), .rxd(rxd),
    .req    (uart_req), .wstrb(uart_pick_write ? data_wr_strb : 4'b0),
    .addr_offset(uart_pick_write ? data_wr_addr[2:0] : data_rd_addr[2:0]),
    .wdata  (data_wr_data), .tag_in(uart_pick_write),
    .ok     (uart_ok), .rdata(uart_rdata), .tag_out(uart_tagout)
);

// ---------------- 取指突发返回路由 ----------------
assign inst_rd_rdy    = base_grant_inst | ext_grant_inst;
assign inst_ret_valid = base_ret_inst | ext_ret_inst;
assign inst_ret_data  = base_ret_inst ? base_rdata : ext_rdata;
assign inst_ret_last  = (base_ret_inst & base_beat_last) | (ext_ret_inst & ext_beat_last);

// ---------------- 访存返回路由 ----------------
assign data_rd_ok   = (base_ok_data & ~base_data_is_write) |
                      (ext_ok_data & ~ext_data_is_write) |
                      (uart_ok & ~uart_tagout);
assign data_wr_ok   = (base_ok_data & base_data_is_write) |
                      (ext_ok_data & ext_data_is_write) |
                      (uart_ok & uart_tagout);
assign data_rd_data = (base_ok_data & ~base_data_is_write) ? base_rdata :
                      (ext_ok_data & ~ext_data_is_write) ? ext_rdata : uart_rdata;

endmodule
