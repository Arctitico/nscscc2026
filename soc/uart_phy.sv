`default_nettype none
// ============================================================================
// 固定格式 UART PHY：115200 baud，8N1。
//
// 计数器采用四舍五入后的整周期分频。50/100 MHz 下单比特误差均远小于
// 115200 UART 的容限；接收端先双触发同步，再在每个数据位中心采样。
// ============================================================================
module uart_tx #(
    parameter integer CLK_FREQ = 50_000_000,
    parameter integer BAUD     = 115200
) (
    input  wire       clk,
    input  wire       reset,
    input  wire       start,
    input  wire [7:0] data,
    output reg        txd,
    output wire       busy
);

localparam integer CLKS_PER_BIT = (CLK_FREQ + BAUD / 2) / BAUD;
localparam integer COUNT_W = $clog2(CLKS_PER_BIT);

reg [COUNT_W-1:0] count;
reg [3:0] bit_index;
reg [7:0] shift;
reg active;

assign busy = active;

always @(posedge clk) begin
    if (reset) begin
        count     <= {COUNT_W{1'b0}};
        bit_index <= 4'd0;
        shift     <= 8'd0;
        active    <= 1'b0;
        txd       <= 1'b1;
    end else if (!active) begin
        txd <= 1'b1;
        if (start) begin
            count     <= CLKS_PER_BIT - 1;
            bit_index <= 4'd0;
            shift     <= data;
            active    <= 1'b1;
            txd       <= 1'b0;
        end
    end else if (count != 0) begin
        count <= count - 1'b1;
    end else begin
        count <= CLKS_PER_BIT - 1;
        if (bit_index < 4'd8) begin
            txd       <= shift[0];
            shift     <= {1'b0, shift[7:1]};
            bit_index <= bit_index + 1'b1;
        end else begin
            txd    <= 1'b1;
            active <= 1'b0;
        end
    end
end

endmodule

module uart_rx #(
    parameter integer CLK_FREQ = 50_000_000,
    parameter integer BAUD     = 115200
) (
    input  wire       clk,
    input  wire       reset,
    input  wire       rxd,
    input  wire       clear,
    output reg        ready,
    output reg  [7:0] data
);

localparam integer CLKS_PER_BIT = (CLK_FREQ + BAUD / 2) / BAUD;
localparam integer HALF_BIT     = CLKS_PER_BIT / 2;
localparam integer COUNT_W      = $clog2(CLKS_PER_BIT);
localparam [1:0] RX_IDLE = 2'd0, RX_START = 2'd1, RX_DATA = 2'd2, RX_STOP = 2'd3;

reg [1:0] sync;
reg [1:0] state;
reg [COUNT_W-1:0] count;
reg [2:0] bit_index;
reg [7:0] shift;

always @(posedge clk) begin
    if (reset) begin
        sync      <= 2'b11;
        state     <= RX_IDLE;
        count     <= {COUNT_W{1'b0}};
        bit_index <= 3'd0;
        shift     <= 8'd0;
        data      <= 8'd0;
        ready     <= 1'b0;
    end else begin
        sync <= {sync[0], rxd};
        if (clear)
            ready <= 1'b0;

        case (state)
        RX_IDLE: if (!sync[1]) begin
            count <= HALF_BIT - 1;
            state <= RX_START;
        end
        RX_START: if (count != 0) begin
            count <= count - 1'b1;
        end else if (!sync[1]) begin
            count     <= CLKS_PER_BIT - 1;
            bit_index <= 3'd0;
            state     <= RX_DATA;
        end else begin
            state <= RX_IDLE;
        end
        RX_DATA: if (count != 0) begin
            count <= count - 1'b1;
        end else begin
            shift[bit_index] <= sync[1];
            count <= CLKS_PER_BIT - 1;
            if (bit_index == 3'd7)
                state <= RX_STOP;
            else
                bit_index <= bit_index + 1'b1;
        end
        RX_STOP: if (count != 0) begin
            count <= count - 1'b1;
        end else begin
            if (sync[1]) begin
                data  <= shift;
                ready <= 1'b1;
            end
            state <= RX_IDLE;
        end
        default: state <= RX_IDLE;
        endcase
    end
end

endmodule
`default_nettype wire
