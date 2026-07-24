`timescale 1ns/1ps

module tb_uart;
    localparam integer CLK_FREQ = 50_000_000;
    localparam integer BAUD = 115200;
    localparam integer CLKS_PER_BIT = (CLK_FREQ + BAUD / 2) / BAUD;

    reg clk;
    reg reset;
    reg start;
    reg [7:0] tx_data;
    wire txd;
    wire tx_busy;
    wire rx_ready;
    wire [7:0] rx_data;
    reg rx_clear;

    uart_tx #(.CLK_FREQ(CLK_FREQ), .BAUD(BAUD)) u_tx (
        .clk(clk), .reset(reset), .start(start), .data(tx_data),
        .txd(txd), .busy(tx_busy)
    );

    uart_rx #(.CLK_FREQ(CLK_FREQ), .BAUD(BAUD)) u_rx (
        .clk(clk), .reset(reset), .rxd(txd), .clear(rx_clear),
        .ready(rx_ready), .data(rx_data)
    );

    task automatic send_byte(input [7:0] value);
        begin
            while (tx_busy)
                @(posedge clk);
            tx_data = value;
            start = 1'b1;
            @(posedge clk);
            start = 1'b0;
        end
    endtask

    integer received;
    integer busy_cycles;
    always @(posedge clk) begin
        if (reset) begin
            received <= 0;
            busy_cycles <= 0;
            rx_clear <= 1'b0;
        end else begin
            rx_clear <= rx_ready;
            if (tx_busy)
                busy_cycles <= busy_cycles + 1;
            if (rx_ready && !rx_clear) begin
                case (received)
                    0: if (rx_data !== 8'h4d)
                           $fatal(1, "UART byte 0 mismatch: %02x", rx_data);
                    1: if (rx_data !== 8'ha5)
                           $fatal(1, "UART byte 1 mismatch: %02x", rx_data);
                    default: $fatal(1, "unexpected UART byte: %02x", rx_data);
                endcase
                received <= received + 1;
            end
        end
    end

    initial clk = 1'b0;
    always #10 clk = ~clk;

    initial begin
        reset = 1'b1;
        start = 1'b0;
        tx_data = 8'b0;
        rx_clear = 1'b0;
        repeat (4) @(posedge clk);
        reset = 1'b0;

        send_byte(8'h4d);
        send_byte(8'ha5);

        wait (received == 2);
        wait (!tx_busy);
        if (busy_cycles < 2 * 10 * CLKS_PER_BIT)
            $fatal(1, "UART busy window too short: %0d cycles", busy_cycles);
        $display("==== UART TEST PASSED ====");
        $finish;
    end

    initial begin
        repeat (25 * CLKS_PER_BIT) @(posedge clk);
        $fatal(1, "UART TEST TIMEOUT");
    end
endmodule
