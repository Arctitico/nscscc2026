`default_nettype none
// ============================================================================
// 2026 板级顶层：CPU 私有类 SRAM 口直接连接 BaseRAM / ExtRAM / UART。
//
// 本设计没有 AXI、跨时钟 AXI 桥或官方参考 SoC。CPU、cache、仲裁器和物理 SRAM
// 控制器工作在同一个 cpu_clk 域。SIMULATION=1 时旁路 PLL，便于顶层仿真。
// ============================================================================
module soc_top #(
    parameter integer SIMULATION         = 0,
    parameter integer CPU_CLK_HZ          = 50_000_000,
    parameter integer PLL_DIVCLK_DIVIDE   = 1,
    parameter integer PLL_CLKFBOUT_MULT   = 18,
    parameter integer PLL_CLKOUT0_DIVIDE  = 18,
    parameter integer SRAM_READ_CYCLES       = 3,
    parameter integer SRAM_WRITE_CYCLES      = 3,
    parameter integer SRAM_WRITE_HOLD_CYCLES = 1
) (
    input  wire        clk,
    input  wire        reset,

    output wire [ 2:0] video_red,
    output wire [ 2:0] video_green,
    output wire [ 1:0] video_blue,
    output wire        video_hsync,
    output wire        video_vsync,
    output wire        video_clk,
    output wire        video_de,

    input  wire [ 3:0] touch_btn,
    input  wire [31:0] dip_sw,
    output wire [15:0] leds,
    output wire [ 7:0] dpy0,
    output wire [ 7:0] dpy1,

    inout  wire [31:0] base_ram_data,
    output wire [19:0] base_ram_addr,
    output wire [ 3:0] base_ram_be_n,
    output wire        base_ram_ce_n,
    output wire        base_ram_oe_n,
    output wire        base_ram_we_n,

    inout  wire [31:0] ext_ram_data,
    output wire [19:0] ext_ram_addr,
    output wire [ 3:0] ext_ram_be_n,
    output wire        ext_ram_ce_n,
    output wire        ext_ram_oe_n,
    output wire        ext_ram_we_n,

    input  wire        UART_RX,
    output wire        UART_TX
);

wire cpu_clk;
wire clock_locked;

generate
if (SIMULATION != 0) begin : g_sim_clock
    assign cpu_clk = clk;
    assign clock_locked = ~reset;
end else begin : g_board_clock
    board_clock #(
        .DIVCLK_DIVIDE (PLL_DIVCLK_DIVIDE),
        .CLKFBOUT_MULT (PLL_CLKFBOUT_MULT),
        .CLKOUT0_DIVIDE(PLL_CLKOUT0_DIVIDE)
    ) u_clock (
        .clk_in (clk),
        .reset  (reset),
        .cpu_clk(cpu_clk),
        .locked (clock_locked)
    );
end
endgenerate

// 异步置位、同步释放复位。reset_pipe 的 INIT=11 也保证 FPGA 刚配置完成而
// PLL 尚未输出时钟时，板级 SRAM/UART 引脚仍处于安全状态。
reg [1:0] reset_pipe = 2'b11;
always @(posedge cpu_clk or negedge clock_locked) begin
    if (!clock_locked)
        reset_pipe <= 2'b11;
    else
        reset_pipe <= {reset_pipe[0], 1'b0};
end
wire cpu_reset = reset_pipe[1];
wire io_active = ~cpu_reset;

wire        inst_rd_req;
wire [31:0] inst_rd_addr;
wire        inst_rd_rdy;
wire        inst_ret_valid;
wire [31:0] inst_ret_data;
wire        inst_ret_last;

wire        data_rd_req;
wire [ 2:0] data_rd_size;
wire [31:0] data_rd_addr;
wire [31:0] data_rd_data;
wire        data_rd_ok;
wire        data_wr_req;
wire [ 2:0] data_wr_size;
wire [31:0] data_wr_addr;
wire [ 3:0] data_wr_strb;
wire [31:0] data_wr_data;
wire        data_wr_ok;

wire [31:0] base_ram_wdat;
wire [31:0] ext_ram_wdat;
wire        base_ram_wdrive;
wire        ext_ram_wdrive;
wire [19:0] base_ram_addr_int;
wire [ 3:0] base_ram_be_n_int;
wire        base_ram_ce_n_int;
wire        base_ram_oe_n_int;
wire        base_ram_we_n_int;
wire [19:0] ext_ram_addr_int;
wire [ 3:0] ext_ram_be_n_int;
wire        ext_ram_ce_n_int;
wire        ext_ram_oe_n_int;
wire        ext_ram_we_n_int;

// BaseRAM 低 8 位与板载下载控制器共享。PLL 尚未起振时，后级同步逻辑没有
// 时钟可执行 reset 分支，因此不能直接把控制器寄存器接到引脚。用带 INIT 的
// cpu_reset 在顶层强制撤销片选/读写使能和数据驱动，避免下载 monitor 时争用
// SRAM；ExtRAM 同样采用安全门控。
assign base_ram_addr = base_ram_addr_int;
assign base_ram_be_n = io_active ? base_ram_be_n_int : 4'hf;
assign base_ram_ce_n = io_active ? base_ram_ce_n_int : 1'b1;
assign base_ram_oe_n = io_active ? base_ram_oe_n_int : 1'b1;
assign base_ram_we_n = io_active ? base_ram_we_n_int : 1'b1;
assign base_ram_data = (io_active & base_ram_wdrive) ? base_ram_wdat : 32'bz;

assign ext_ram_addr = ext_ram_addr_int;
assign ext_ram_be_n = io_active ? ext_ram_be_n_int : 4'hf;
assign ext_ram_ce_n = io_active ? ext_ram_ce_n_int : 1'b1;
assign ext_ram_oe_n = io_active ? ext_ram_oe_n_int : 1'b1;
assign ext_ram_we_n = io_active ? ext_ram_we_n_int : 1'b1;
assign ext_ram_data = (io_active & ext_ram_wdrive) ? ext_ram_wdat : 32'bz;

wire uart_txd;
wire uart_rxd = UART_RX;
assign UART_TX = io_active ? uart_txd : 1'b1;

mycpu_top u_cpu (
    .clk            (cpu_clk),
    .resetn         (~cpu_reset),
    .inst_rd_req    (inst_rd_req),
    .inst_rd_addr   (inst_rd_addr),
    .inst_rd_rdy    (inst_rd_rdy),
    .inst_ret_valid (inst_ret_valid),
    .inst_ret_data  (inst_ret_data),
    .inst_ret_last  (inst_ret_last),
    .data_rd_req    (data_rd_req),
    .data_rd_size   (data_rd_size),
    .data_rd_addr   (data_rd_addr),
    .data_rd_data   (data_rd_data),
    .data_rd_ok     (data_rd_ok),
    .data_wr_req    (data_wr_req),
    .data_wr_size   (data_wr_size),
    .data_wr_addr   (data_wr_addr),
    .data_wr_strb   (data_wr_strb),
    .data_wr_data   (data_wr_data),
    .data_wr_ok     (data_wr_ok),
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

mem_bridge #(
    .SRAM_READ_CYCLES(SRAM_READ_CYCLES),
    .SRAM_WRITE_CYCLES(SRAM_WRITE_CYCLES),
    .SRAM_WRITE_HOLD_CYCLES(SRAM_WRITE_HOLD_CYCLES),
    .CLK_FREQ(CPU_CLK_HZ)
) u_bridge (
    .clk            (cpu_clk),
    .reset          (cpu_reset),
    .inst_rd_req    (inst_rd_req),
    .inst_rd_addr   (inst_rd_addr),
    .inst_rd_rdy    (inst_rd_rdy),
    .inst_ret_valid (inst_ret_valid),
    .inst_ret_data  (inst_ret_data),
    .inst_ret_last  (inst_ret_last),
    .data_rd_req    (data_rd_req),
    .data_rd_size   (data_rd_size),
    .data_rd_addr   (data_rd_addr),
    .data_rd_data   (data_rd_data),
    .data_rd_ok     (data_rd_ok),
    .data_wr_req    (data_wr_req),
    .data_wr_size   (data_wr_size),
    .data_wr_addr   (data_wr_addr),
    .data_wr_strb   (data_wr_strb),
    .data_wr_data   (data_wr_data),
    .data_wr_ok     (data_wr_ok),
    .base_ram_addr  (base_ram_addr_int),
    .base_ram_be_n  (base_ram_be_n_int),
    .base_ram_ce_n  (base_ram_ce_n_int),
    .base_ram_oe_n  (base_ram_oe_n_int),
    .base_ram_we_n  (base_ram_we_n_int),
    .base_ram_wdrive(base_ram_wdrive),
    .base_ram_wdat  (base_ram_wdat),
    .base_ram_rdat  (base_ram_data),
    .ext_ram_addr   (ext_ram_addr_int),
    .ext_ram_be_n   (ext_ram_be_n_int),
    .ext_ram_ce_n   (ext_ram_ce_n_int),
    .ext_ram_oe_n   (ext_ram_oe_n_int),
    .ext_ram_we_n   (ext_ram_we_n_int),
    .ext_ram_wdrive (ext_ram_wdrive),
    .ext_ram_wdat   (ext_ram_wdat),
    .ext_ram_rdat   (ext_ram_data),
    .txd            (uart_txd),
    .rxd            (uart_rxd)
);

assign leds        = 16'b0;
assign dpy0        = 8'b0;
assign dpy1        = 8'b0;
assign video_red   = 3'b0;
assign video_green = 3'b0;
assign video_blue  = 2'b0;
assign video_hsync = 1'b0;
assign video_vsync = 1'b0;
assign video_clk   = 1'b0;
assign video_de    = 1'b0;

wire unused_inputs = ^{touch_btn, dip_sw};

endmodule
`default_nettype wire
