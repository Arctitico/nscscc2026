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
    wire        data_rd_req, data_rd_ok;
    wire [ 2:0] data_rd_size;
    wire [31:0] data_rd_addr, data_rd_data;
    wire        data_wr_req, data_wr_ok;
    wire [ 2:0] data_wr_size;
    wire [31:0] data_wr_addr, data_wr_data;
    wire [ 3:0] data_wr_strb;

    wire [31:0] debug_wb_pc;
    wire [ 3:0] debug_wb_rf_we;
    wire [ 4:0] debug_wb_rf_wnum;
    wire [31:0] debug_wb_rf_wdata;
    wire [31:0] debug_wb1_pc;
    wire [ 3:0] debug_wb1_rf_we;
    wire [ 4:0] debug_wb1_rf_wnum;
    wire [31:0] debug_wb1_rf_wdata;

    mycpu_top u_cpu(
        .clk(clk), .resetn(resetn),
        .inst_rd_req(inst_rd_req), .inst_rd_addr(inst_rd_addr),
        .inst_rd_rdy(inst_rd_rdy), .inst_ret_valid(inst_ret_valid),
        .inst_ret_data(inst_ret_data), .inst_ret_last(inst_ret_last),
        .data_rd_req(data_rd_req), .data_rd_size(data_rd_size), .data_rd_addr(data_rd_addr),
        .data_rd_data(data_rd_data), .data_rd_ok(data_rd_ok),
        .data_wr_req(data_wr_req), .data_wr_size(data_wr_size), .data_wr_addr(data_wr_addr),
        .data_wr_strb(data_wr_strb), .data_wr_data(data_wr_data), .data_wr_ok(data_wr_ok),
        .debug_wb_pc(debug_wb_pc), .debug_wb_inst(), .debug_wb_rf_we(debug_wb_rf_we),
        .debug_wb_rf_wnum(debug_wb_rf_wnum), .debug_wb_rf_wdata(debug_wb_rf_wdata),
        .debug_wb1_pc(debug_wb1_pc), .debug_wb1_inst(), .debug_wb1_rf_we(debug_wb1_rf_we),
        .debug_wb1_rf_wnum(debug_wb1_rf_wnum), .debug_wb1_rf_wdata(debug_wb1_rf_wdata)
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
    reg        ractive, rline, wactive;
    reg [ 2:0] rbeat;
    reg [31:0] rbase;
    wire [31:0] rbeat_addr = rbase + (rbeat << 2);
    wire rdaccept = data_rd_req & ~ractive;
    wire wraccept = data_wr_req & ~wactive;
    assign data_rd_ok = ractive;
    assign data_wr_ok = wactive;
    assign data_rd_data = is_base(rbeat_addr) ? base_mem[idx(rbeat_addr)] :
                          is_ext(rbeat_addr)  ? ext_mem[idx(rbeat_addr)]  : 32'h0;
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
        if (!resetn) begin
            ractive <= 1'b0;
            wactive <= 1'b0;
            rbeat   <= 3'd0;
        end else begin
            if (rdaccept) begin
                ractive <= 1'b1;
                rline   <= (data_rd_size == 3'b100);
                rbeat   <= 3'd0;
                rbase   <= data_rd_addr;
            end else if (ractive) begin
                if (rline && (rbeat != 3'd3))
                    rbeat <= rbeat + 3'd1;
                else
                    ractive <= 1'b0;
            end
            if (wraccept)
                wactive <= 1'b1;
            else if (wactive)
                wactive <= 1'b0;
        end

        if (wraccept && is_base(data_wr_addr)) begin
            if (data_wr_strb[0]) base_mem[idx(data_wr_addr)][ 7: 0] <= data_wr_data[ 7: 0];
            if (data_wr_strb[1]) base_mem[idx(data_wr_addr)][15: 8] <= data_wr_data[15: 8];
            if (data_wr_strb[2]) base_mem[idx(data_wr_addr)][23:16] <= data_wr_data[23:16];
            if (data_wr_strb[3]) base_mem[idx(data_wr_addr)][31:24] <= data_wr_data[31:24];
        end
        if (wraccept && is_ext(data_wr_addr)) begin
            if (data_wr_strb[0]) ext_mem[idx(data_wr_addr)][ 7: 0] <= data_wr_data[ 7: 0];
            if (data_wr_strb[1]) ext_mem[idx(data_wr_addr)][15: 8] <= data_wr_data[15: 8];
            if (data_wr_strb[2]) ext_mem[idx(data_wr_addr)][23:16] <= data_wr_data[23:16];
            if (data_wr_strb[3]) ext_mem[idx(data_wr_addr)][31:24] <= data_wr_data[31:24];
        end
    end

    // ---- 黄金参考 ----
    reg [31:0] g_pc  [0:MAXT-1];
    reg [31:0] g_wn  [0:MAXT-1];
    reg [31:0] g_wd  [0:MAXT-1];
    reg [31:0] g_mem [0:MAXT-1];
    integer ncommit, nmem;

    // ---- 锁步比对（同拍按 slot0、slot1 的程序序检查）----
    integer tptr, errors;

    task automatic check_commit(input [31:0] cpc, input [4:0] cwn, input [31:0] cwd);
        if (tptr >= ncommit) begin
            $display("  FAIL extra commit #%0d pc=%08x r%0d<=%08x (golden 已耗尽, 期望 %0d 条)",
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

    always @(posedge clk) begin
        if (resetn) begin
            if (|debug_wb_rf_we)  check_commit(debug_wb_pc, debug_wb_rf_wnum, debug_wb_rf_wdata);
            if (|debug_wb1_rf_we) check_commit(debug_wb1_pc, debug_wb1_rf_wnum, debug_wb1_rf_wdata);
            if ($test$plusargs("trace_mem") && data_wr_req)
                $display("[STORE] pc0=%08x pc1=%08x v1=%0b addr=%08x we=%x data=%08x",
                         u_cpu.u_EX.s0.pc, u_cpu.u_EX.s1.pc, u_cpu.u_EX.ex_v1_eff,
                         data_wr_addr, data_wr_strb, data_wr_data);
            if ($test$plusargs("trace_tail") && u_cpu.u_CM.cm_valid &&
                (u_cpu.u_CM.cm_r.s0.pc >= 32'h1c000480))
                $display("[CM] pc0=%08x v1=%0b pc1=%08x",
                         u_cpu.u_CM.cm_r.s0.pc, u_cpu.u_CM.cm_r.v1,
                         u_cpu.u_CM.cm_r.s1.pc);
            if ($test$plusargs("trace_tail") &&
                (u_cpu.u_IF.pc_f1 >= 32'h1c000480))
                $display("[PIPE] f1=%08x req=%0b fire=%0b f2v=%0b ifv=%0b idallow=%0b redirect=%0b target=%08x",
                         u_cpu.u_IF.pc_f1, u_cpu.ic_req, u_cpu.u_IF.f1_fire,
                         u_cpu.u_IF.valid_f2, u_cpu.IF_to_ID_valid, u_cpu.ID_allow_in,
                         u_cpu.redirect, u_cpu.redirect_target);
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
        // 分支可跳过最后数条写寄存器指令；提交黄金流耗尽后，尾部仍可能
        // 有无写回的 store 在流水线中。留足够窗口让它们落盘，同时暴露多提交。
        repeat (200) @(posedge clk);

        // ---- 结果 ----
        if (tptr < ncommit) begin
            $display("  FAIL 仅提交 %0d / %0d 条 (CPU 卡住或超时)", tptr, ncommit);
            $display("  ROB head=%0d tail=%0d count=%0d head_valid=%0b head_ready=%0b pc=%08x",
                     u_cpu.u_rob.head, u_cpu.u_rob.tail, u_cpu.u_rob.count,
                     u_cpu.u_rob.entries[u_cpu.u_rob.head].valid,
                     u_cpu.u_rob.entries[u_cpu.u_rob.head].ready,
                     u_cpu.u_rob.entries[u_cpu.u_rob.head].pc);
            $display("  PIPE rr=%0b dp_count=%0d is=%0b rf=%0b ex=%0b wb=%0b redirect=%0b",
                     u_cpu.u_RR.rr_valid, u_cpu.u_DP.count, u_cpu.u_IS.is_valid,
                     u_cpu.u_RF.rf_valid, u_cpu.u_EX.ex_valid, u_cpu.u_WB.wb_valid,
                     u_cpu.redirect);
            $display("  FRONT f1_pc=%08x f2_valid=%0b if_valid=%0b next_golden_pc=%08x",
                     u_cpu.u_IF.pc_f1, u_cpu.u_IF.valid_f2, u_cpu.IF_to_ID_valid,
                     g_pc[tptr]);
            $display("  FREELIST bitmap=%016x", u_cpu.u_RR.free_bitmap);
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
