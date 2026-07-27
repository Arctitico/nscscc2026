// 2026 第一阶段：52 字节程序计算并回读 64 个 Fibonacci 结果。
module tb_level1;
    localparam int DEPTH = 'h10000;

    reg clk_50M;
    reg reset_btn;
    wire txd;
    wire [31:0] base_ram_data, ext_ram_data;
    wire [19:0] base_ram_addr, ext_ram_addr;
    wire [ 3:0] base_ram_be_n, ext_ram_be_n;
    wire base_ram_ce_n, base_ram_oe_n, base_ram_we_n;
    wire ext_ram_ce_n, ext_ram_oe_n, ext_ram_we_n;
    wire [15:0] leds;
    wire [7:0] dpy0, dpy1;
    wire [2:0] video_red, video_green;
    wire [1:0] video_blue;
    wire video_hsync, video_vsync, video_clk, video_de;

    thinpad_top #(
        .SIMULATION               (1),
        .CPU_CLK_HZ               (50_000_000),
        .SRAM_READ_CYCLES         (3),
        .SRAM_WRITE_CYCLES        (3),
        .SRAM_WRITE_HOLD_CYCLES   (1)
    ) u_dut (
        .clk(clk_50M), .reset(reset_btn), .touch_btn(4'b0), .dip_sw(32'b0),
        .leds(leds), .dpy0(dpy0), .dpy1(dpy1),
        .base_ram_data(base_ram_data), .base_ram_addr(base_ram_addr),
        .base_ram_be_n(base_ram_be_n), .base_ram_ce_n(base_ram_ce_n),
        .base_ram_oe_n(base_ram_oe_n), .base_ram_we_n(base_ram_we_n),
        .ext_ram_data(ext_ram_data), .ext_ram_addr(ext_ram_addr),
        .ext_ram_be_n(ext_ram_be_n), .ext_ram_ce_n(ext_ram_ce_n),
        .ext_ram_oe_n(ext_ram_oe_n), .ext_ram_we_n(ext_ram_we_n),
        .UART_TX(txd), .UART_RX(1'b1),
        .video_red(video_red), .video_green(video_green), .video_blue(video_blue),
        .video_hsync(video_hsync), .video_vsync(video_vsync),
        .video_clk(video_clk), .video_de(video_de)
    );

    reg [31:0] base_mem [0:DEPTH-1];
    reg [31:0] ext_mem  [0:DEPTH-1];

    assign base_ram_data = (~base_ram_ce_n & ~base_ram_oe_n & base_ram_we_n && base_ram_addr < DEPTH)
                         ? base_mem[base_ram_addr] : 32'bz;
    assign ext_ram_data  = (~ext_ram_ce_n & ~ext_ram_oe_n & ext_ram_we_n && ext_ram_addr < DEPTH)
                         ? ext_mem[ext_ram_addr] : 32'bz;

    always @(posedge clk_50M) begin
        if (~reset_btn & ~base_ram_ce_n & ~base_ram_we_n & (base_ram_addr < DEPTH)) begin
            if (~base_ram_be_n[0]) base_mem[base_ram_addr][ 7: 0] <= u_dut.base_ram_wdat[ 7: 0];
            if (~base_ram_be_n[1]) base_mem[base_ram_addr][15: 8] <= u_dut.base_ram_wdat[15: 8];
            if (~base_ram_be_n[2]) base_mem[base_ram_addr][23:16] <= u_dut.base_ram_wdat[23:16];
            if (~base_ram_be_n[3]) base_mem[base_ram_addr][31:24] <= u_dut.base_ram_wdat[31:24];
        end
        if (~reset_btn & ~ext_ram_ce_n & ~ext_ram_we_n & (ext_ram_addr < DEPTH)) begin
            if (~ext_ram_be_n[0]) ext_mem[ext_ram_addr][ 7: 0] <= u_dut.ext_ram_wdat[ 7: 0];
            if (~ext_ram_be_n[1]) ext_mem[ext_ram_addr][15: 8] <= u_dut.ext_ram_wdat[15: 8];
            if (~ext_ram_be_n[2]) ext_mem[ext_ram_addr][23:16] <= u_dut.ext_ram_wdat[23:16];
            if (~ext_ram_be_n[3]) ext_mem[ext_ram_addr][31:24] <= u_dut.ext_ram_wdat[31:24];
        end
    end

    initial clk_50M = 1'b0;
    always #10 clk_50M = ~clk_50M;

    integer i;
    integer guard;
    integer errors;
    reg [31:0] a, b, next_value;
    initial begin
        for (i = 0; i < DEPTH; i = i + 1) begin
            base_mem[i] = 32'b0;
            ext_mem[i]  = 32'hdead_beef;
        end
        $readmemh("level1.hex", base_mem);

        reset_btn = 1'b1;
        repeat (8) @(posedge clk_50M);
        reset_btn = 1'b0;

        guard = 0;
        while ((ext_mem[63] === 32'hdead_beef) && guard < 500_000) begin
            @(posedge clk_50M);
            guard = guard + 1;
        end
        repeat (20) @(posedge clk_50M);

        errors = 0;
        a = 1;
        b = 1;
        for (i = 0; i < 64; i = i + 1) begin
            next_value = a + b;
            if (ext_mem[i] !== next_value) begin
                if (errors < 8)
                    $display("FAIL fibonacci[%0d]=%08x expected=%08x", i, ext_mem[i], next_value);
                errors = errors + 1;
            end
            a = b;
            b = next_value;
        end

        if (ext_mem[63] === 32'hdead_beef) begin
            $display("FAIL level1 timeout");
            errors = errors + 1;
        end
        if (errors == 0) begin
            $display("==== LEVEL1 TEST PASSED ====");
            $finish;
        end else begin
            $fatal(1, "==== LEVEL1 TEST FAILED: %0d errors ====", errors);
        end
    end
endmodule
