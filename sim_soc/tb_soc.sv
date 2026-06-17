// ============================================================================
// tb_soc.sv —— SoC 级功能仿真（verilator --binary --timing）
//
// 跑「真实多周期访存路径」：thinpad_top（mycpu_top + mem_bridge）对接行为级异步
// SRAM 模型，验证 icache 突发重填/data_ok 停顿、地址译码、BaseRAM 取指 ∥ 访存「访存优先」
// 仲裁（本测试代码与数据同在 BaseRAM，恰好压同片仲裁这一最关键路径）。
//
// 程序复用 sim/asm.py 生成的 test.hex（装载基址 0x80000000，与片内字地址 [21:2] 同序）。
// 自检：① 读 BaseRAM 模型里程序写回的 3 处内存；② 经层次引用窥视 CPU 提交流核对寄存器。
// ============================================================================
module tb_soc;
    localparam int DEPTH = 'h42000;     // 覆盖到 0x80108000

    reg  clk_50M;
    reg  reset_btn;
    reg  rxd;
    wire txd;

    // RAM 物理总线
    wire [31:0] base_ram_data, ext_ram_data;
    wire [19:0] base_ram_addr, ext_ram_addr;
    wire [ 3:0] base_ram_be_n, ext_ram_be_n;
    wire        base_ram_ce_n, base_ram_oe_n, base_ram_we_n;
    wire        ext_ram_ce_n,  ext_ram_oe_n,  ext_ram_we_n;

    // 未用外设
    wire [15:0] leds;  wire [7:0] dpy0, dpy1;
    wire [22:0] flash_a;  wire [15:0] flash_d;
    wire flash_rp_n, flash_vpen, flash_ce_n, flash_oe_n, flash_we_n, flash_byte_n;
    wire [2:0] video_red, video_green;  wire [1:0] video_blue;
    wire video_hsync, video_vsync, video_clk, video_de;

    thinpad_top u_dut (
        .clk_50M(clk_50M), .clk_11M0592(1'b0),
        .clock_btn(1'b0),  .reset_btn(reset_btn),
        .touch_btn(4'b0),  .dip_sw(32'b0),
        .leds(leds), .dpy0(dpy0), .dpy1(dpy1),
        .base_ram_data(base_ram_data), .base_ram_addr(base_ram_addr), .base_ram_be_n(base_ram_be_n),
        .base_ram_ce_n(base_ram_ce_n), .base_ram_oe_n(base_ram_oe_n), .base_ram_we_n(base_ram_we_n),
        .ext_ram_data(ext_ram_data), .ext_ram_addr(ext_ram_addr), .ext_ram_be_n(ext_ram_be_n),
        .ext_ram_ce_n(ext_ram_ce_n), .ext_ram_oe_n(ext_ram_oe_n), .ext_ram_we_n(ext_ram_we_n),
        .txd(txd), .rxd(rxd),
        .flash_a(flash_a), .flash_d(flash_d), .flash_rp_n(flash_rp_n), .flash_vpen(flash_vpen),
        .flash_ce_n(flash_ce_n), .flash_oe_n(flash_oe_n), .flash_we_n(flash_we_n), .flash_byte_n(flash_byte_n),
        .video_red(video_red), .video_green(video_green), .video_blue(video_blue),
        .video_hsync(video_hsync), .video_vsync(video_vsync), .video_clk(video_clk), .video_de(video_de)
    );

    // ---- 行为级异步 SRAM 模型 ----
    reg [31:0] base_mem [0:DEPTH-1];
    reg [31:0] ext_mem  [0:DEPTH-1];

    // 读：ce&oe 低、we 高 → 驱动总线；否则放开（高阻）由 thinpad 驱动写数据
    assign base_ram_data = (~base_ram_ce_n & ~base_ram_oe_n & base_ram_we_n)
                         ? base_mem[base_ram_addr] : 32'bz;
    assign ext_ram_data  = (~ext_ram_ce_n  & ~ext_ram_oe_n  & ext_ram_we_n )
                         ? ext_mem[ext_ram_addr]  : 32'bz;

    // 写：we 低期间（多拍幂等），按字节使能在 clk 沿写入（此时总线由 thinpad 驱动 wdat）
    always @(posedge clk_50M) begin
        if (~base_ram_ce_n & ~base_ram_we_n) begin
            if (~base_ram_be_n[0]) base_mem[base_ram_addr][ 7: 0] <= base_ram_data[ 7: 0];
            if (~base_ram_be_n[1]) base_mem[base_ram_addr][15: 8] <= base_ram_data[15: 8];
            if (~base_ram_be_n[2]) base_mem[base_ram_addr][23:16] <= base_ram_data[23:16];
            if (~base_ram_be_n[3]) base_mem[base_ram_addr][31:24] <= base_ram_data[31:24];
        end
        if (~ext_ram_ce_n & ~ext_ram_we_n) begin
            if (~ext_ram_be_n[0]) ext_mem[ext_ram_addr][ 7: 0] <= ext_ram_data[ 7: 0];
            if (~ext_ram_be_n[1]) ext_mem[ext_ram_addr][15: 8] <= ext_ram_data[15: 8];
            if (~ext_ram_be_n[2]) ext_mem[ext_ram_addr][23:16] <= ext_ram_data[23:16];
            if (~ext_ram_be_n[3]) ext_mem[ext_ram_addr][31:24] <= ext_ram_data[31:24];
        end
    end

    // ---- 提交捕获（层次引用 CPU 内部 debug 信号）----
    reg [31:0] arch [0:31];
    integer i, commits;
    reg started;

    always @(posedge clk_50M) begin
        if (started && (|u_dut.u_cpu.debug_wb_rf_we)) begin
            arch[u_dut.u_cpu.debug_wb_rf_wnum] <= u_dut.u_cpu.debug_wb_rf_wdata;
            commits <= commits + 1;
            if (commits < 80)
                $display("[commit %0d] pc=%08x  r%0d <= %08x", commits,
                         u_dut.u_cpu.debug_wb_pc, u_dut.u_cpu.debug_wb_rf_wnum,
                         u_dut.u_cpu.debug_wb_rf_wdata);
        end
    end

    // ---- 时钟 ----
    initial clk_50M = 0;
    always #5 clk_50M = ~clk_50M;

    // ---- 自检 ----
    integer errors;
    task check(input [4:0] r, input [31:0] exp);
        if (arch[r] !== exp) begin
            $display("  FAIL r%0d = %08x, expected %08x", r, arch[r], exp);
            errors = errors + 1;
        end else
            $display("  ok   r%0d = %08x", r, arch[r]);
    endtask
    task checkmem(input int word_idx, input [31:0] exp, input [31:0] disp_addr);
        if (base_mem[word_idx] !== exp) begin
            $display("  FAIL mem[%08x] = %08x, expected %08x", disp_addr, base_mem[word_idx], exp);
            errors = errors + 1;
        end else
            $display("  ok   mem[%08x] = %08x", disp_addr, base_mem[word_idx]);
    endtask

    initial begin
        for (i = 0; i < DEPTH; i = i + 1) begin base_mem[i] = 32'h0; ext_mem[i] = 32'h0; end
        for (i = 0; i < 32;    i = i + 1) arch[i] = 32'hx;
        commits = 0; errors = 0; started = 0; rxd = 1'b1;
        $readmemh("test.hex", base_mem);     // 代码 @0x80000000、数据 @0x80100000 同在 BaseRAM

        reset_btn = 1;
        repeat (8) @(posedge clk_50M);
        reset_btn = 0;
        started   = 1;

        repeat (8000) @(posedge clk_50M);    // 多周期访存较慢，给足时间

        $display("==== checking architectural state (commits=%0d) ====", commits);
        check(5'd2,  32'd0);
        check(5'd3,  32'd55);
        check(5'd4,  32'd55);
        check(5'd5,  32'd110);
        check(5'd6,  32'h1ff);
        check(5'd7,  32'hffffffff);
        check(5'd8,  32'd54);
        check(5'd9,  32'hABCDEF01);
        check(5'd10, 32'hF01);
        check(5'd11, 32'hF010);
        check(5'd12, 32'hF0);
        check(5'd13, 32'd0);
        check(5'd14, 32'hFF1);
        check(5'd15, 32'hF01);
        check(5'd16, 32'd55);
        check(5'd18, 32'h18);
        check(5'd19, 32'h19);
        check(5'd21, 32'h21);
        checkmem('h40000, 32'd55,        32'h80100000);
        checkmem('h40001, 32'h000000ff, 32'h80100004);
        checkmem('h40002, 32'h21,        32'h80100008);

        if (errors == 0) $display("==== SOC TEST PASSED ====");
        else             $display("==== SOC TEST FAILED: %0d errors ====", errors);
        $finish;
    end
endmodule
