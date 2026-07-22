// ============================================================================
// tb_soc_rand.sv —— SoC 级随机指令 DiffTest (verilator --binary --timing)
//
// 在「真实多周期访存路径」(thinpad_top: mycpu_top + mem_bridge + 异步 SRAM 模型)上
// 跑随机程序并锁步比对黄金提交流。代码在 BaseRAM，scratch 在 ExtRAM。
// 激励由 ../sim/randgen.py 生成 (test.hex / golden_trace.hex / golden_mem.hex / golden.meta)。
// ============================================================================
module tb_soc_rand;
    localparam logic [31:0] SCRATCH = 32'h1c40_0000;
    localparam int          DEPTH   = 'h10000;
    localparam int          SCR_W   = 'h00000;
    localparam int          MAXT    = 200000;

    reg  clk_50M, reset_btn, rxd;
    wire txd;

    wire [31:0] base_ram_data, ext_ram_data;
    wire [19:0] base_ram_addr, ext_ram_addr;
    wire [ 3:0] base_ram_be_n, ext_ram_be_n;
    wire        base_ram_ce_n, base_ram_oe_n, base_ram_we_n;
    wire        ext_ram_ce_n,  ext_ram_oe_n,  ext_ram_we_n;
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
    // 注意(Verilator inout 建模): 写回若从共享网 base_ram_data 取数, 会与「读驱动 base_ram_data
    // <- base_mem」构成组合环(UNOPTFLAT), Verilator 的 inout 解析顺序随编译而变 → 读出时序非确定
    // (首拍取指可能读到 0)。这里写回改用层次引用 DUT 内部写数据 u_dut.*_ram_wdat, 断开此环,
    // 使 tb 成为读路径上 base_ram_data 的唯一有效驱动, 读出稳定可重复。
    reg [31:0] base_mem [0:DEPTH-1];
    reg [31:0] ext_mem  [0:DEPTH-1];
    assign base_ram_data = (~base_ram_ce_n & ~base_ram_oe_n & base_ram_we_n) ? base_mem[base_ram_addr] : 32'bz;
    assign ext_ram_data  = (~ext_ram_ce_n  & ~ext_ram_oe_n  & ext_ram_we_n ) ? ext_mem[ext_ram_addr]  : 32'bz;
    always @(posedge clk_50M) begin
        if (~reset_btn & ~base_ram_ce_n & ~base_ram_we_n) begin
            if (~base_ram_be_n[0]) base_mem[base_ram_addr][ 7: 0] <= u_dut.base_ram_wdat[ 7: 0];
            if (~base_ram_be_n[1]) base_mem[base_ram_addr][15: 8] <= u_dut.base_ram_wdat[15: 8];
            if (~base_ram_be_n[2]) base_mem[base_ram_addr][23:16] <= u_dut.base_ram_wdat[23:16];
            if (~base_ram_be_n[3]) base_mem[base_ram_addr][31:24] <= u_dut.base_ram_wdat[31:24];
        end
        if (~reset_btn & ~ext_ram_ce_n & ~ext_ram_we_n) begin
            if (~ext_ram_be_n[0]) ext_mem[ext_ram_addr][ 7: 0] <= u_dut.ext_ram_wdat[ 7: 0];
            if (~ext_ram_be_n[1]) ext_mem[ext_ram_addr][15: 8] <= u_dut.ext_ram_wdat[15: 8];
            if (~ext_ram_be_n[2]) ext_mem[ext_ram_addr][23:16] <= u_dut.ext_ram_wdat[23:16];
            if (~ext_ram_be_n[3]) ext_mem[ext_ram_addr][31:24] <= u_dut.ext_ram_wdat[31:24];
        end
    end

    // ---- 黄金参考 ----
    reg [31:0] g_pc  [0:MAXT-1];
    reg [31:0] g_wn  [0:MAXT-1];
    reg [31:0] g_wd  [0:MAXT-1];
    reg [31:0] g_mem [0:MAXT-1];
    integer ncommit, nmem;

    // ---- 锁步比对（同拍先 slot0 后 slot1）----
    integer tptr, errors;
    reg started;

    task automatic check_commit(input [31:0] cpc, input [4:0] cwn, input [31:0] cwd);
        if (tptr >= ncommit) begin
            $display("  FAIL extra commit #%0d pc=%08x r%0d<=%08x (golden 已耗尽, 期望 %0d)",
                     tptr, cpc, cwn, cwd, ncommit);
            errors = errors + 1;
        end else if (cpc !== g_pc[tptr] || {27'b0,cwn} !== g_wn[tptr] || cwd !== g_wd[tptr]) begin
            $display("  FAIL commit #%0d", tptr);
            $display("    DUT   : pc=%08x r%0d <= %08x", cpc, cwn, cwd);
            $display("    GOLDEN: pc=%08x r%0d <= %08x", g_pc[tptr], g_wn[tptr], g_wd[tptr]);
            errors = errors + 1;
        end
        tptr = tptr + 1;
    endtask

    always @(posedge clk_50M) begin
        if (started) begin
            if (|u_dut.u_cpu.debug_wb_rf_we)
                check_commit(u_dut.u_cpu.debug_wb_pc, u_dut.u_cpu.debug_wb_rf_wnum,
                             u_dut.u_cpu.debug_wb_rf_wdata);
            if (|u_dut.u_cpu.debug_wb1_rf_we)
                check_commit(u_dut.u_cpu.debug_wb1_pc, u_dut.u_cpu.debug_wb1_rf_wnum,
                             u_dut.u_cpu.debug_wb1_rf_wdata);
        end
    end

    initial clk_50M = 0;
    always #5 clk_50M = ~clk_50M;

    integer fd, code, i, k;
    reg [31:0] t_pc, t_wn, t_wd;
    integer guard;
    initial begin
`ifdef DUMP
        $dumpfile("dump.vcd"); $dumpvars(0, tb_soc_rand);
`endif
        for (i = 0; i < DEPTH; i = i + 1) begin base_mem[i] = 32'h0; ext_mem[i] = 32'h0; end
        tptr = 0; errors = 0; started = 0; rxd = 1'b1;

        $readmemh("test.hex",       base_mem);   // 代码 @0x1c000000，scratch @ExtRAM 0
        $readmemh("golden_mem.hex", g_mem);
        fd = $fopen("golden.meta", "r");
        code = $fscanf(fd, "%d %d", ncommit, nmem);
        $fclose(fd);
        fd = $fopen("golden_trace.hex", "r");
        i = 0;
        code = $fscanf(fd, "%h %h %h", t_pc, t_wn, t_wd);
        while (code == 3 && i < MAXT) begin
            g_pc[i] = t_pc; g_wn[i] = t_wn; g_wd[i] = t_wd; i = i + 1;
            code = $fscanf(fd, "%h %h %h", t_pc, t_wn, t_wd);
        end
        $fclose(fd);
        $display("==== SoC DiffTest 开始: 期望 %0d 条提交, scratch %0d 字 ====", ncommit, nmem);

        reset_btn = 1;
        repeat (8) @(posedge clk_50M);
        reset_btn = 0;
        started   = 1;

        // 多周期访存慢, 给足 guard (按经验每条 commit 数十拍)
        guard = 0;
        while (tptr < ncommit && guard < 200*ncommit + 20000) begin
            @(posedge clk_50M); guard = guard + 1;
        end
        // 多周期 SoC 访存下，黄金写回流耗尽后尾部 store 可仍在途。
        repeat (1000) @(posedge clk_50M);

        if (tptr < ncommit) begin
            $display("  FAIL 仅提交 %0d / %0d 条 (CPU 卡住或超时)", tptr, ncommit);
            errors = errors + 1;
        end
        for (k = 0; k < nmem; k = k + 1) begin
            if (ext_mem[SCR_W + k] !== g_mem[k]) begin
                $display("  FAIL mem[%08x] = %08x, expected %08x",
                         SCRATCH + k*4, ext_mem[SCR_W + k], g_mem[k]);
                errors = errors + 1;
            end
        end

        $display("==== checked: commits=%0d/%0d, mem=%0d words ====", tptr, ncommit, nmem);
        if (errors == 0) $display("==== SOC RAND TEST PASSED ====");
        else             $display("==== SOC RAND TEST FAILED: %0d errors ====", errors);
        $finish;
    end
endmodule
