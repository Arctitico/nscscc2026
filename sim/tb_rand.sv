// ============================================================================
// tb_rand.sv —— mycpu_top 随机指令 DiffTest 平台 (verilator --binary --timing)
//
// 与 tb.sv 共用同一行为级组合读内存模型, 但自检改为「锁步比对黄金提交流」:
//   每拍 CPU 提交(debug_wb_rf_we!=0) 与 golden_trace.hex 的下一条 (pc,wnum,wdata)
//   逐条比对, 首个不一致即报当前 pc 并停止; 运行结束再比对 scratch 内存镜像。
// 程序与黄金参考由 randgen.py 生成 (test.hex / golden_trace.hex / golden_mem.hex /
// golden.meta)。
// ============================================================================
module tb_rand;
    localparam logic [31:0] BASE    = 32'h8000_0000;
    localparam logic [31:0] SCRATCH = 32'h8010_0000;
    localparam int          DEPTH   = 'h42000;        // 覆盖到 0x80108000
    localparam int          MAXT    = 200000;         // 提交流/内存数组上限

    reg clk, resetn;

    wire        inst_sram_en;
    wire [ 3:0] inst_sram_we;
    wire [31:0] inst_sram_addr, inst_sram_wdata, inst_sram_rdata;
    wire        data_sram_en;
    wire [ 3:0] data_sram_we;
    wire [31:0] data_sram_addr, data_sram_wdata, data_sram_rdata;

    wire [31:0] debug_wb_pc;
    wire [ 3:0] debug_wb_rf_we;
    wire [ 4:0] debug_wb_rf_wnum;
    wire [31:0] debug_wb_rf_wdata;

    mycpu_top u_cpu(
        .clk(clk), .resetn(resetn),
        .inst_sram_en(inst_sram_en), .inst_sram_we(inst_sram_we),
        .inst_sram_addr(inst_sram_addr), .inst_sram_wdata(inst_sram_wdata),
        .inst_sram_rdata(inst_sram_rdata), .inst_ok(1'b1),
        .data_sram_en(data_sram_en), .data_sram_we(data_sram_we),
        .data_sram_addr(data_sram_addr), .data_sram_wdata(data_sram_wdata),
        .data_sram_rdata(data_sram_rdata), .data_ok(1'b1),
        .debug_wb_pc(debug_wb_pc), .debug_wb_rf_we(debug_wb_rf_we),
        .debug_wb_rf_wnum(debug_wb_rf_wnum), .debug_wb_rf_wdata(debug_wb_rf_wdata)
    );

    // ---- 行为级内存 (组合读, 沿写) ----
    reg [31:0] mem [0:DEPTH-1];
    function automatic int  idx(input [31:0] a);     idx = (a - BASE) >> 2; endfunction
    function automatic bit  inrange(input [31:0] a); inrange = (a >= BASE) && (idx(a) < DEPTH); endfunction
    assign inst_sram_rdata = inrange(inst_sram_addr) ? mem[idx(inst_sram_addr)] : 32'h0;
    assign data_sram_rdata = inrange(data_sram_addr) ? mem[idx(data_sram_addr)] : 32'h0;
    always @(posedge clk) begin
        if (data_sram_en && (|data_sram_we) && inrange(data_sram_addr)) begin
            if (data_sram_we[0]) mem[idx(data_sram_addr)][ 7: 0] <= data_sram_wdata[ 7: 0];
            if (data_sram_we[1]) mem[idx(data_sram_addr)][15: 8] <= data_sram_wdata[15: 8];
            if (data_sram_we[2]) mem[idx(data_sram_addr)][23:16] <= data_sram_wdata[23:16];
            if (data_sram_we[3]) mem[idx(data_sram_addr)][31:24] <= data_sram_wdata[31:24];
        end
    end

    // ---- 黄金参考 ----
    reg [31:0] g_pc  [0:MAXT-1];
    reg [31:0] g_wn  [0:MAXT-1];
    reg [31:0] g_wd  [0:MAXT-1];
    reg [31:0] g_mem [0:MAXT-1];
    integer ncommit, nmem;

    // ---- 锁步比对 ----
    integer tptr, errors;

    always @(posedge clk) begin
        if (resetn && (|debug_wb_rf_we)) begin
            if (tptr >= ncommit) begin
                $display("  FAIL extra commit #%0d pc=%08x r%0d<=%08x (golden 已耗尽, 期望 %0d 条)",
                         tptr, debug_wb_pc, debug_wb_rf_wnum, debug_wb_rf_wdata, ncommit);
                errors = errors + 1;
            end else begin
                if (debug_wb_pc !== g_pc[tptr] ||
                    {27'b0,debug_wb_rf_wnum} !== g_wn[tptr] ||
                    debug_wb_rf_wdata !== g_wd[tptr]) begin
                    $display("  FAIL commit #%0d", tptr);
                    $display("    DUT   : pc=%08x r%0d <= %08x",
                             debug_wb_pc, debug_wb_rf_wnum, debug_wb_rf_wdata);
                    $display("    GOLDEN: pc=%08x r%0d <= %08x",
                             g_pc[tptr], g_wn[tptr], g_wd[tptr]);
                    errors = errors + 1;
                end
            end
            tptr = tptr + 1;
        end
    end

    // ---- 时钟 ----
    initial clk = 0;
    always #5 clk = ~clk;

    // ---- 主流程 ----
    integer fd, code, i, k;
    reg [31:0] t_pc, t_wn, t_wd;
    integer guard;
    initial begin
        for (i = 0; i < DEPTH; i = i + 1) mem[i] = 32'h0;
        tptr = 0; errors = 0;

        $readmemh("test.hex",       mem);
        $readmemh("golden_mem.hex", g_mem);
        // 读 meta: "ncommit nmem"
        fd = $fopen("golden.meta", "r");
        code = $fscanf(fd, "%d %d", ncommit, nmem);
        $fclose(fd);
        // 读提交流: 每行 "<pc> <wnum> <wdata>" (hex)
        fd = $fopen("golden_trace.hex", "r");
        i = 0;
        code = $fscanf(fd, "%h %h %h", t_pc, t_wn, t_wd);
        while (code == 3 && i < MAXT) begin
            g_pc[i] = t_pc; g_wn[i] = t_wn; g_wd[i] = t_wd;
            i = i + 1;
            code = $fscanf(fd, "%h %h %h", t_pc, t_wn, t_wd);
        end
        $fclose(fd);
        if (i != ncommit) begin
            $display("WARN: trace 行数 %0d 与 meta ncommit %0d 不符", i, ncommit);
        end
        $display("==== DiffTest 开始: 期望 %0d 条提交, scratch %0d 字 ====", ncommit, nmem);

        resetn = 0;
        repeat (4) @(posedge clk);
        resetn = 1;

        // 跑到全部提交流被消费(再多留几拍捕获多余提交), 或超时
        guard = 0;
        while (tptr < ncommit && guard < 20*ncommit + 2000) begin
            @(posedge clk); guard = guard + 1;
        end
        repeat (20) @(posedge clk);   // 留窗口暴露「多提交」

        // ---- 结果 ----
        if (tptr < ncommit) begin
            $display("  FAIL 仅提交 %0d / %0d 条 (CPU 卡住或超时)", tptr, ncommit);
            errors = errors + 1;
        end
        // 比对 scratch 内存
        for (k = 0; k < nmem; k = k + 1) begin
            if (mem[idx(SCRATCH) + k] !== g_mem[k]) begin
                $display("  FAIL mem[%08x] = %08x, expected %08x",
                         SCRATCH + k*4, mem[idx(SCRATCH)+k], g_mem[k]);
                errors = errors + 1;
            end
        end

        $display("==== checked: commits=%0d/%0d, mem=%0d words ====", tptr, ncommit, nmem);
        if (errors == 0) $display("==== RAND TEST PASSED ====");
        else             $display("==== RAND TEST FAILED: %0d errors ====", errors);
        $finish;
    end
endmodule
