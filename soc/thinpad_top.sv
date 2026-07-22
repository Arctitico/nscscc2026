`default_nettype none
// ============================================================================
// thinpad_top —— 板级顶层（替换官方模版同名 demo）
//
// 引脚表与官方模版完全一致，可直接加入 2025_nscscc 个人赛模版工程并设为顶层，
// 也能被模版 sim_1/new/tb.sv（接 sram_model + cpld 串口模型）仿真。
//
// 结构：clk = clk_50M（直接用，复位为 reset_btn 同步后高有效）；
//   mycpu_top（顺序单发射，取指突发读口 + 访存单字 data_ok 停顿）
//     ↕ mem_bridge（地址译码 + 访存优先仲裁 + BaseRAM/ExtRAM 多周期控制器 + UART）
//   物理 inout 数据线的三态在本层完成。其余外设（Flash/VGA/数码管/LED）置为非活动。
//
// 2026 地址映射：0x1c000000–0x1c3fffff→BaseRAM，
//   0x1c400000–0x1c7fffff→ExtRAM，0x1f000000–0x1f0fffff→UART。
// UART_DATA=0x1f000000，UART_STATUS=0x1f000005；复位 PC=0x1c000000。
// ============================================================================
module thinpad_top (
    input  wire        clk_50M,        // 50MHz 时钟输入
    input  wire        clk_11M0592,    // 11.0592MHz 时钟输入（备用，可不用）

    input  wire        clock_btn,      // BTN5 手动时钟按钮，带消抖，按下为 1
    input  wire        reset_btn,      // BTN6 手动复位按钮，带消抖，按下为 1

    input  wire [ 3:0] touch_btn,      // BTN1~BTN4，按下为 1
    input  wire [31:0] dip_sw,         // 32 位拨码开关，ON 为 1
    output wire [15:0] leds,           // 16 位 LED，输出 1 点亮
    output wire [ 7:0] dpy0,           // 数码管低位（含小数点）
    output wire [ 7:0] dpy1,           // 数码管高位（含小数点）

    // BaseRAM 信号
    inout  wire [31:0] base_ram_data,  // 低 8 位与 CPLD 串口控制器共享
    output wire [19:0] base_ram_addr,
    output wire [ 3:0] base_ram_be_n,
    output wire        base_ram_ce_n,
    output wire        base_ram_oe_n,
    output wire        base_ram_we_n,

    // ExtRAM 信号
    inout  wire [31:0] ext_ram_data,
    output wire [19:0] ext_ram_addr,
    output wire [ 3:0] ext_ram_be_n,
    output wire        ext_ram_ce_n,
    output wire        ext_ram_oe_n,
    output wire        ext_ram_we_n,

    // 直连串口
    output wire        txd,
    input  wire        rxd,

    // Flash（本工程不用，禁用）
    output wire [22:0] flash_a,
    inout  wire [15:0] flash_d,
    output wire        flash_rp_n,
    output wire        flash_vpen,
    output wire        flash_ce_n,
    output wire        flash_oe_n,
    output wire        flash_we_n,
    output wire        flash_byte_n,

    // 图像输出（本工程不用，禁用）
    output wire [ 2:0] video_red,
    output wire [ 2:0] video_green,
    output wire [ 1:0] video_blue,
    output wire        video_hsync,
    output wire        video_vsync,
    output wire        video_clk,
    output wire        video_de
);

// ---------------- 时钟与复位 ----------------
wire clk = clk_50M;

// reset_btn 同步进 clk 域，高有效；上电默认处于复位
reg [1:0] rst_sync = 2'b11;
always @(posedge clk) rst_sync <= {rst_sync[0], reset_btn};
wire rst = rst_sync[1];

// ---------------- CPU ↔ 桥 内部连线 ----------------
wire        inst_rd_req;
wire [31:0] inst_rd_addr;
wire        inst_rd_rdy;
wire        inst_ret_valid;
wire [31:0] inst_ret_data;
wire        inst_ret_last;

wire        data_sram_en;
wire [ 3:0] data_sram_we;
wire [ 2:0] data_sram_size_unused;
wire [31:0] data_sram_addr;
wire [31:0] data_sram_wdata;
wire [31:0] data_sram_rdata;
wire        data_ok;

// ---------------- SRAM 写数据（三态在本层）----------------
wire [31:0] base_ram_wdat;
wire [31:0] ext_ram_wdat;

assign base_ram_data = base_ram_we_n ? 32'bz : base_ram_wdat;  // we_n 低=写，驱动总线
assign ext_ram_data  = ext_ram_we_n  ? 32'bz : ext_ram_wdat;

// ---------------- CPU ----------------
mycpu_top u_cpu (
    .clk            (clk            ),
    .resetn         (~rst           ),
    .inst_rd_req    (inst_rd_req    ),
    .inst_rd_addr   (inst_rd_addr   ),
    .inst_rd_rdy    (inst_rd_rdy    ),
    .inst_ret_valid (inst_ret_valid ),
    .inst_ret_data  (inst_ret_data  ),
    .inst_ret_last  (inst_ret_last  ),
    .data_sram_en   (data_sram_en   ),
    .data_sram_we   (data_sram_we   ),
    .data_sram_size (data_sram_size_unused),
    .data_sram_addr (data_sram_addr ),
    .data_sram_wdata(data_sram_wdata ),
    .data_sram_rdata(data_sram_rdata ),
    .data_ok        (data_ok        ),
    .debug_wb_pc      (),
    .debug_wb_inst    (),
    .debug_wb_rf_we   (),
    .debug_wb_rf_wnum (),
    .debug_wb_rf_wdata(),
    .debug_wb1_pc      (),
    .debug_wb1_inst    (),
    .debug_wb1_rf_we   (),
    .debug_wb1_rf_wnum (),
    .debug_wb1_rf_wdata()
);

// ---------------- 访存桥 ----------------
mem_bridge #(.SRAM_LATENCY(2)) u_bridge (
    .clk            (clk            ),
    .reset          (rst            ),
    .inst_rd_req    (inst_rd_req    ),
    .inst_rd_addr   (inst_rd_addr   ),
    .inst_rd_rdy    (inst_rd_rdy    ),
    .inst_ret_valid (inst_ret_valid ),
    .inst_ret_data  (inst_ret_data  ),
    .inst_ret_last  (inst_ret_last  ),
    .data_sram_en   (data_sram_en   ),
    .data_sram_we   (data_sram_we   ),
    .data_sram_addr (data_sram_addr ),
    .data_sram_wdata(data_sram_wdata),
    .data_sram_rdata(data_sram_rdata),
    .data_ok        (data_ok        ),
    .base_ram_addr  (base_ram_addr  ),
    .base_ram_be_n  (base_ram_be_n  ),
    .base_ram_ce_n  (base_ram_ce_n  ),
    .base_ram_oe_n  (base_ram_oe_n  ),
    .base_ram_we_n  (base_ram_we_n  ),
    .base_ram_wdat  (base_ram_wdat  ),
    .base_ram_rdat  (base_ram_data  ),
    .ext_ram_addr   (ext_ram_addr   ),
    .ext_ram_be_n   (ext_ram_be_n   ),
    .ext_ram_ce_n   (ext_ram_ce_n   ),
    .ext_ram_oe_n   (ext_ram_oe_n   ),
    .ext_ram_we_n   (ext_ram_we_n   ),
    .ext_ram_wdat   (ext_ram_wdat   ),
    .ext_ram_rdat   (ext_ram_data   ),
    .txd            (txd            ),
    .rxd            (rxd            )
);

// ---------------- 未使用外设：置非活动 ----------------
assign leds        = 16'b0;
assign dpy0        = 8'b0;
assign dpy1        = 8'b0;

assign flash_a     = 23'b0;
assign flash_d     = 16'bz;
assign flash_rp_n  = 1'b1;
assign flash_vpen  = 1'b0;
assign flash_ce_n  = 1'b1;
assign flash_oe_n  = 1'b1;
assign flash_we_n  = 1'b1;
assign flash_byte_n= 1'b1;

assign video_red   = 3'b0;
assign video_green = 3'b0;
assign video_blue  = 2'b0;
assign video_hsync = 1'b0;
assign video_vsync = 1'b0;
assign video_clk   = 1'b0;
assign video_de    = 1'b0;

endmodule

`default_nettype wire
