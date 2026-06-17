// ============================================================================
// uart_mm —— 内存映射串口（监控程序约定）
//
// 复用官方模版 async.v 里的 RS-232 收发器（async_transmitter/async_receiver，
// 9600/8/N/1，监控程序正是按它收发），外裹一层寄存器访问：
//   0xBFD003F8（reg_sel=addr[2]=0）数据寄存器：读=接收字节{24'b0,rx}；写=发送 wdata[7:0]
//   0xBFD003FC（reg_sel=1）         状态寄存器：读={…, bit1=接收有数据, bit0=发送就绪}
// 监控程序轮询状态：发送前等 bit0=1 再写数据；接收前等 bit1=1 再读数据。
//
// 握手与 sram_ctrl 一致（req 保持到 ok，tag 原样带回）；寄存器访问 1 拍完成。
// 注：async_transmitter/async_receiver 来自模版 async.v，本仓不复制，Vivado 工程
//     沿用模版那份；Verilator SoC 仿真在 Makefile 里按路径带上模版 async.v。
// ============================================================================
module uart_mm (
    input  wire        clk,
    input  wire        reset,

    // 直连串口物理引脚
    output wire        txd,
    input  wire        rxd,

    // 请求侧（单口；req 保持到 ok）
    input  wire        req,
    input  wire [ 3:0] wstrb,    // 0=读，非 0=写
    input  wire        reg_sel,  // addr[2]：0=数据寄存器，1=状态寄存器
    input  wire [31:0] wdata,
    input  wire        tag_in,
    output reg         ok,
    output reg  [31:0] rdata,
    output reg         tag_out
);

// ---- 物理收发器（官方 PHY，9600/8/N/1）----
reg        tx_start;
reg  [7:0] tx_data;
wire       tx_busy;
wire       rx_ready;
wire [7:0] rx_data;
reg        rx_clear;

async_transmitter #(.ClkFrequency(50_000_000), .Baud(9600)) u_tx (
    .clk      (clk     ),
    .TxD_start(tx_start),
    .TxD_data (tx_data ),
    .TxD      (txd     ),
    .TxD_busy (tx_busy )
);

async_receiver #(.ClkFrequency(50_000_000), .Baud(9600)) u_rx (
    .clk           (clk     ),
    .RxD           (rxd     ),
    .RxD_data_ready(rx_ready),
    .RxD_clear     (rx_clear),
    .RxD_data      (rx_data )
);

wire [31:0] status = {30'b0, rx_ready, ~tx_busy};   // bit1=接收有数据 bit0=发送就绪
wire        is_wr  = |wstrb;

localparam S_IDLE = 1'b0, S_DONE = 1'b1;
reg state;

always @(posedge clk) begin
    if (reset) begin
        state <= S_IDLE; ok <= 1'b0; rdata <= 32'b0; tag_out <= 1'b0;
        tx_start <= 1'b0; tx_data <= 8'b0; rx_clear <= 1'b0;
    end else begin
        ok <= 1'b0; tx_start <= 1'b0; rx_clear <= 1'b0;   // 默认 1-shot
        case (state)
        S_IDLE: if (req) begin
            tag_out <= tag_in;
            if (reg_sel) begin                            // 状态寄存器（写忽略）
                rdata <= status;
            end else if (is_wr) begin                     // 数据寄存器：写 → 发送
                tx_data  <= wdata[7:0];
                tx_start <= 1'b1;
            end else begin                                // 数据寄存器：读 → 取字节并清标志
                rdata    <= {24'b0, rx_data};
                rx_clear <= 1'b1;
            end
            ok    <= 1'b1;
            state <= S_DONE;
        end
        S_DONE: state <= S_IDLE;
        endcase
    end
end

endmodule
