// ============================================================================
// mem_bridge —— CPU 类 SRAM 双口（取指/访存）→ 板上 BaseRAM/ExtRAM/UART 桥
//
// 把 CPU 的两条「请求保持到 ok」端口接到两片异步 SRAM + 串口：
//   地址译码（按 addr[23:22]，与往届参考一致）：00=BaseRAM 01=ExtRAM 11=UART。
//   片内字地址 = addr[21:2]（每片 1M 字 = 4MB）。
//
// 仲裁：BaseRAM/ExtRAM 各一个独立 sram_ctrl，可并行（典型：取指走 Base ∥ 访存走 Ext）。
//   当取指与访存命中同一片时，**访存优先**（较老指令先走，避免在途访存被新取指饿死；
//   取指属投机、可等待）。每个控制器用 tag(0=取指/1=访存) 记住正在服务谁，ok 据此回送。
//   UART 仅访存口可达（指令不会从串口取指）。
//
// 三态：物理 inout 数据线在板级顶层 thinpad_top 处理，本模块只出 *_wdat + 控制位、
//   入 *_rdat（故可综合也可被 Verilator 直接仿真）。
// ============================================================================
module mem_bridge #(
    parameter integer SRAM_LATENCY = 2
) (
    input  wire        clk,
    input  wire        reset,

    // ---- CPU 取指口（只读；req 保持到 inst_ok）----
    input  wire        inst_sram_en,
    input  wire [31:0] inst_sram_addr,
    output wire [31:0] inst_sram_rdata,
    output wire        inst_ok,

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

// ---------------- 地址译码 ----------------
wire inst_base = inst_sram_en & (inst_sram_addr[23:22] == 2'b00);
wire inst_ext  = inst_sram_en & (inst_sram_addr[23:22] == 2'b01);
wire data_base = data_sram_en & (data_sram_addr[23:22] == 2'b00);
wire data_ext  = data_sram_en & (data_sram_addr[23:22] == 2'b01);
wire data_uart = data_sram_en & (data_sram_addr[23:22] == 2'b11);

// ---------------- BaseRAM 仲裁（访存优先）----------------
wire        base_pick_data = data_base;
wire        base_req       = data_base | inst_base;
wire [19:0] base_acc_addr  = base_pick_data ? data_sram_addr[21:2] : inst_sram_addr[21:2];
wire [ 3:0] base_wstrb     = base_pick_data ? data_sram_we         : 4'b0;   // 取指必为读
wire        base_tagin     = base_pick_data ? 1'b1                  : 1'b0;

wire        base_ok;
wire [31:0] base_rdata;
wire        base_tagout;

sram_ctrl #(.LATENCY(SRAM_LATENCY)) u_base (
    .clk     (clk          ), .reset(reset),
    .ram_addr(base_ram_addr), .ram_be_n(base_ram_be_n),
    .ram_ce_n(base_ram_ce_n), .ram_oe_n(base_ram_oe_n), .ram_we_n(base_ram_we_n),
    .ram_wdat(base_ram_wdat), .ram_rdat(base_ram_rdat),
    .req     (base_req     ), .wstrb(base_wstrb), .addr(base_acc_addr),
    .wdata   (data_sram_wdata), .tag_in(base_tagin),
    .ok      (base_ok      ), .rdata(base_rdata), .tag_out(base_tagout), .busy()
);

wire base_ok_inst = base_ok & ~base_tagout;
wire base_ok_data = base_ok &  base_tagout;

// ---------------- ExtRAM 仲裁（访存优先）----------------
wire        ext_pick_data = data_ext;
wire        ext_req       = data_ext | inst_ext;
wire [19:0] ext_acc_addr  = ext_pick_data ? data_sram_addr[21:2] : inst_sram_addr[21:2];
wire [ 3:0] ext_wstrb     = ext_pick_data ? data_sram_we         : 4'b0;
wire        ext_tagin     = ext_pick_data ? 1'b1                  : 1'b0;

wire        ext_ok;
wire [31:0] ext_rdata;
wire        ext_tagout;

sram_ctrl #(.LATENCY(SRAM_LATENCY)) u_ext (
    .clk     (clk         ), .reset(reset),
    .ram_addr(ext_ram_addr), .ram_be_n(ext_ram_be_n),
    .ram_ce_n(ext_ram_ce_n), .ram_oe_n(ext_ram_oe_n), .ram_we_n(ext_ram_we_n),
    .ram_wdat(ext_ram_wdat), .ram_rdat(ext_ram_rdat),
    .req     (ext_req     ), .wstrb(ext_wstrb), .addr(ext_acc_addr),
    .wdata   (data_sram_wdata), .tag_in(ext_tagin),
    .ok      (ext_ok      ), .rdata(ext_rdata), .tag_out(ext_tagout), .busy()
);

wire ext_ok_inst = ext_ok & ~ext_tagout;
wire ext_ok_data = ext_ok &  ext_tagout;

// ---------------- UART（仅访存）----------------
wire        uart_ok;
wire [31:0] uart_rdata;

uart_mm u_uart (
    .clk    (clk           ), .reset(reset),
    .txd    (txd           ), .rxd(rxd),
    .req    (data_uart     ), .wstrb(data_sram_we), .reg_sel(data_sram_addr[2]),
    .wdata  (data_sram_wdata), .tag_in(1'b1),
    .ok     (uart_ok       ), .rdata(uart_rdata), .tag_out()
);

// ---------------- ok / rdata 路由 ----------------
// 同一时刻取指只在途一片、访存只在途一处，故各 ok 互斥，可直接或/选。
assign inst_ok    = base_ok_inst | ext_ok_inst;
assign inst_sram_rdata = base_ok_inst ? base_rdata : ext_rdata;

assign data_ok    = base_ok_data | ext_ok_data | uart_ok;
assign data_sram_rdata = base_ok_data ? base_rdata :
                         ext_ok_data  ? ext_rdata  : uart_rdata;

endmodule
