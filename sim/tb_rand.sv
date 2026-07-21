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
    localparam logic [31:0] SCRATCH = 32'h1c40_0000;
    localparam int          DEPTH   = 'h10000;
    localparam int          MAXT    = 200000;         // 提交流/内存数组上限

    reg clk, resetn;

    wire        inst_rd_req;
    wire [31:0] inst_rd_addr;
    wire        inst_rd_rdy, inst_ret_valid, inst_ret_last;
    wire [31:0] inst_ret_data;
    wire        data_sram_en;
    wire [ 3:0] data_sram_we;
    wire [31:0] data_sram_addr, data_sram_wdata, data_sram_rdata;

    wire [31:0] debug_wb_pc;
    wire [ 3:0] debug_wb_rf_we;
    wire [ 4:0] debug_wb_rf_wnum;
    wire [31:0] debug_wb_rf_wdata;

    mycpu_top u_cpu(
        .clk(clk), .resetn(resetn),
        .inst_rd_req(inst_rd_req), .inst_rd_addr(inst_rd_addr),
        .inst_rd_rdy(inst_rd_rdy), .inst_ret_valid(inst_ret_valid),
        .inst_ret_data(inst_ret_data), .inst_ret_last(inst_ret_last),
        .data_sram_en(data_sram_en), .data_sram_we(data_sram_we),
        .data_sram_size(),
        .data_sram_addr(data_sram_addr), .data_sram_wdata(data_sram_wdata),
        .data_sram_rdata(data_sram_rdata), .data_ok(1'b1),
        .debug_wb_pc(debug_wb_pc), .debug_wb_inst(), .debug_wb_rf_we(debug_wb_rf_we),
        .debug_wb_rf_wnum(debug_wb_rf_wnum), .debug_wb_rf_wdata(debug_wb_rf_wdata)
    );

    // ---- 行为级内存 (组合读, 沿写) ----
    reg [31:0] base_mem [0:DEPTH-1];
    reg [31:0] ext_mem  [0:DEPTH-1];
    function automatic int idx(input [31:0] a); idx = a[21:2]; endfunction
    function automatic bit is_base(input [31:0] a);
        is_base = (a[31:22] == 10'h070) && (idx(a) < DEPTH);
    endfunction
    function automatic bit is_ext(input [31:0] a);
        is_ext = (a[31:22] == 10'h071) && (idx(a) < DEPTH);
    endfunction
    assign data_sram_rdata = is_base(data_sram_addr) ? base_mem[idx(data_sram_addr)] :
                             is_ext(data_sram_addr)  ? ext_mem[idx(data_sram_addr)]  : 32'h0;
    // 取指口：行为级突发读模型（接受当拍 rd_rdy，随后逐拍回 IWORDS 个字）
    localparam int IWORDS = 4;
    reg        iactive;
    reg [ 2:0] iw;
    reg [31:0] ibase;
    wire        iaccept    = inst_rd_req & ~iactive;
    wire [31:0] ibeat_addr = ibase + (iw << 2);
    assign inst_rd_rdy    = iaccept;
    assign inst_ret_valid = iactive;
    assign inst_ret_data  = is_base(ibeat_addr) ? base_mem[idx(ibeat_addr)] :
                            is_ext(ibeat_addr)  ? ext_mem[idx(ibeat_addr)]  : 32'h0;
    assign inst_ret_last  = iactive & (iw == IWORDS-1);
    always @(posedge clk) begin
        if (!resetn)      begin iactive <= 1'b0; iw <= 3'd0; end
        else if (iaccept) begin iactive <= 1'b1; iw <= 3'd0; ibase <= inst_rd_addr; end
        else if (iactive) begin
            iw <= iw + 3'd1;
            if (iw == IWORDS-1) iactive <= 1'b0;
        end
    end
    always @(posedge clk) begin
        if (data_sram_en && (|data_sram_we) && is_base(data_sram_addr)) begin
            if (data_sram_we[0]) base_mem[idx(data_sram_addr)][ 7: 0] <= data_sram_wdata[ 7: 0];
            if (data_sram_we[1]) base_mem[idx(data_sram_addr)][15: 8] <= data_sram_wdata[15: 8];
            if (data_sram_we[2]) base_mem[idx(data_sram_addr)][23:16] <= data_sram_wdata[23:16];
            if (data_sram_we[3]) base_mem[idx(data_sram_addr)][31:24] <= data_sram_wdata[31:24];
        end
        if (data_sram_en && (|data_sram_we) && is_ext(data_sram_addr)) begin
            if (data_sram_we[0]) ext_mem[idx(data_sram_addr)][ 7: 0] <= data_sram_wdata[ 7: 0];
            if (data_sram_we[1]) ext_mem[idx(data_sram_addr)][15: 8] <= data_sram_wdata[15: 8];
            if (data_sram_we[2]) ext_mem[idx(data_sram_addr)][23:16] <= data_sram_wdata[23:16];
            if (data_sram_we[3]) ext_mem[idx(data_sram_addr)][31:24] <= data_sram_wdata[31:24];
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
        for (i = 0; i < DEPTH; i = i + 1) begin base_mem[i] = 32'h0; ext_mem[i] = 32'h0; end
        tptr = 0; errors = 0;

        $readmemh("test.hex",       base_mem);
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
            if (ext_mem[idx(SCRATCH) + k] !== g_mem[k]) begin
                $display("  FAIL mem[%08x] = %08x, expected %08x",
                         SCRATCH + k*4, ext_mem[idx(SCRATCH)+k], g_mem[k]);
                errors = errors + 1;
            end
        end

        $display("==== checked: commits=%0d/%0d, mem=%0d words ====", tptr, ncommit, nmem);
        if (errors == 0) $display("==== RAND TEST PASSED ====");
        else             $display("==== RAND TEST FAILED: %0d errors ====", errors);
        $finish;
    end
endmodule
