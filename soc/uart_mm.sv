// ============================================================================
// uart_mm —— 2026 supervisor 使用的最小 16550 风格内存映射 UART
//
// 物理地址由 mem_bridge 译码，本模块接收窗口内低 3 位偏移：
//   +0 UART_DATA：写低 8 位发送，读返回接收字节
//   +5 UART_STATUS：bit0=RX_READY，bit5=TX_READY
// supervisor 初始化还会写 +1/+2/+3/+4；这里保存最小 DLAB/LCR 状态并安全忽略
// 无关配置。物理串口固定为 115200 baud、8N1。
//
// CPU 的 ld.b 在 WB 按地址低两位选择 byte lane，因此读字节必须放到地址对应
// 的 32 位 lane 中；例如 +5 的状态字节放在 rdata[15:8]。
// ============================================================================
module uart_mm #(
    parameter integer CLK_FREQ = 50_000_000
) (
    input  wire        clk,
    input  wire        reset,

    output wire        txd,
    input  wire        rxd,

    input  wire        req,
    input  wire [ 3:0] wstrb,
    input  wire [ 2:0] addr_offset,
    input  wire [31:0] wdata,
    input  wire        tag_in,
    output reg         ok,
    output reg  [31:0] rdata,
    output reg         tag_out
);

reg        tx_start;
reg  [7:0] tx_data;
wire       tx_busy;
wire       rx_ready;
wire [7:0] rx_data;
reg        rx_clear;

uart_tx #(.CLK_FREQ(CLK_FREQ), .BAUD(115200)) u_tx (
    .clk   (clk),
    .reset (reset),
    .start (tx_start),
    .data  (tx_data),
    .txd   (txd),
    .busy  (tx_busy)
);

uart_rx #(.CLK_FREQ(CLK_FREQ), .BAUD(115200)) u_rx (
    .clk   (clk),
    .reset (reset),
    .rxd   (rxd),
    .clear (rx_clear),
    .ready (rx_ready),
    .data  (rx_data)
);

wire [7:0] status_byte = {2'b0, ~tx_busy, 4'b0, rx_ready};
wire       is_write    = |wstrb;

// 仅 DLAB 行为会影响 +0/+1 的含义；波特率固定，DLL/DLH 只保存供调试。
reg [7:0] lcr;
reg [7:0] dll;
reg [7:0] dlh;
wire      dlab = lcr[7];

localparam S_IDLE = 1'b0;
localparam S_DONE = 1'b1;
reg state;

function automatic [31:0] place_byte(
    input [7:0] value,
    input [1:0] lane
);
    place_byte = {24'b0, value} << (lane * 8);
endfunction

always @(posedge clk) begin
    if (reset) begin
        state     <= S_IDLE;
        ok        <= 1'b0;
        rdata     <= 32'b0;
        tag_out   <= 1'b0;
        tx_start  <= 1'b0;
        tx_data   <= 8'b0;
        rx_clear  <= 1'b0;
        lcr       <= 8'h03;
        dll       <= 8'h00;
        dlh       <= 8'h00;
    end else begin
        ok       <= 1'b0;
        tx_start <= 1'b0;
        rx_clear <= 1'b0;

        case (state)
        S_IDLE: if (req) begin
            tag_out <= tag_in;
            rdata   <= 32'b0;

            if (is_write) begin
                case (addr_offset)
                3'd0: if (dlab) dll <= wdata[7:0];
                      else begin
                          tx_data  <= wdata[7:0];
                          tx_start <= 1'b1;
                      end
                3'd1: if (dlab) dlh <= wdata[7:0];
                3'd3: lcr <= wdata[7:0];
                default: ; // +2 FIFO、+4 modem control：允许写入并忽略
                endcase
            end else begin
                case (addr_offset)
                3'd0: begin
                    rdata    <= place_byte(rx_data, addr_offset[1:0]);
                    rx_clear <= 1'b1;
                end
                3'd5: rdata <= place_byte(status_byte, addr_offset[1:0]);
                default: rdata <= 32'b0;
                endcase
            end

            ok    <= 1'b1;
            state <= S_DONE;
        end
        S_DONE: state <= S_IDLE;
        default: state <= S_IDLE;
        endcase
    end
end

endmodule
