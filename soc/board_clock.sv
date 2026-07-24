`default_nettype none
// ============================================================================
// ThinPAD 50 MHz 输入时钟 -> CPU 时钟。
//
// 构建脚本为指定频率计算一组合法的 7-series PLL 整数参数，并通过顶层 generic
// 传入。把 PLL 写成普通 RTL primitive 后，工程不再依赖生成 IP、DCP 或外部仓库。
// ============================================================================
module board_clock #(
    parameter integer DIVCLK_DIVIDE  = 1,
    parameter integer CLKFBOUT_MULT  = 18,
    parameter integer CLKOUT0_DIVIDE = 18
) (
    input  wire clk_in,
    input  wire reset,
    output wire cpu_clk,
    output wire locked
);

wire clk_in_buf;
wire clk_fb;
wire clk_fb_buf;
wire clk_cpu_raw;
wire [5:0] clk_unused;
wire [15:0] do_unused;
wire drdy_unused;

IBUF u_ibuf (
    .I(clk_in),
    .O(clk_in_buf)
);

PLLE2_ADV #(
    .BANDWIDTH("OPTIMIZED"),
    .COMPENSATION("ZHOLD"),
    .STARTUP_WAIT("FALSE"),
    .DIVCLK_DIVIDE(DIVCLK_DIVIDE),
    .CLKFBOUT_MULT(CLKFBOUT_MULT),
    .CLKFBOUT_PHASE(0.0),
    .CLKOUT0_DIVIDE(CLKOUT0_DIVIDE),
    .CLKOUT0_PHASE(0.0),
    .CLKOUT0_DUTY_CYCLE(0.5),
    .CLKIN1_PERIOD(20.0)
) u_pll (
    .CLKFBOUT(clk_fb),
    .CLKOUT0(clk_cpu_raw),
    .CLKOUT1(clk_unused[0]),
    .CLKOUT2(clk_unused[1]),
    .CLKOUT3(clk_unused[2]),
    .CLKOUT4(clk_unused[3]),
    .CLKOUT5(clk_unused[4]),
    .CLKFBIN(clk_fb_buf),
    .CLKIN1(clk_in_buf),
    .CLKIN2(1'b0),
    .CLKINSEL(1'b1),
    .DADDR(7'd0),
    .DCLK(1'b0),
    .DEN(1'b0),
    .DI(16'd0),
    .DO(do_unused),
    .DRDY(drdy_unused),
    .DWE(1'b0),
    .LOCKED(locked),
    .PWRDWN(1'b0),
    .RST(reset)
);

BUFG u_fb_buf (
    .I(clk_fb),
    .O(clk_fb_buf)
);

BUFG u_cpu_buf (
    .I(clk_cpu_raw),
    .O(cpu_clk)
);

endmodule
`default_nettype wire
