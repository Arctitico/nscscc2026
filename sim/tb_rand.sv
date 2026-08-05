// ============================================================================
// tb_rand.sv —— mycpu_top 随机指令 DiffTest 平台 (verilator --binary --timing)
//
// 与 tb.sv 共用同一行为级组合读内存模型, 但自检改为「锁步比对黄金提交流」:
//   每拍 CPU 提交(debug_wb_rf_we!=0) 与 golden_trace.hex 的下一条 (pc,wnum,wdata)
//   逐条比对, 首个不一致即报当前 pc 并停止; 运行结束再比对 scratch 内存镜像。
// 程序与黄金参考由 randgen.py 生成 (test.hex / initial_mem.hex /
// golden_trace.hex / golden_mem.hex / golden.meta)。
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
    reg [ 4:0] rwait;
    reg [31:0] rbase;
    // CWF line reads start at the requested word and wrap inside the same
    // 16-byte line, matching soc/sram_ctrl.sv.  The old linear addition
    // crossed into the next line whenever the critical word was not word0.
    wire [1:0] rbeat_word = rbase[3:2] + rbeat[1:0];
    wire [31:0] rbeat_addr = rline
                           ? {rbase[31:4], rbeat_word, 2'b00}
                           : rbase;
    wire rdaccept = data_rd_req & ~ractive;
    wire wraccept = data_wr_req & ~wactive;
    assign data_rd_ok = ractive & (rwait == 0);
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
            rwait   <= 5'd0;
        end else begin
            if (rdaccept) begin
                ractive <= 1'b1;
                rline   <= (data_rd_size == 3'b100);
                rbeat   <= 3'd0;
                rbase   <= data_rd_addr;
                rwait   <= $test$plusargs("SLOW_DATA_RESPONSE") ?
                           5'd20 : 5'd0;
            end else if (ractive) begin
                if (rwait != 0)
                    rwait <= rwait - 5'd1;
                else if (rline && (rbeat != 3'd3))
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
    integer mul_accept_streak, max_mul_accept_streak, mul_turnovers;
    integer late_data_matches;
    integer late_data_direct_accepts;
    integer late_data_capture_events;
    integer late_data_retry_accepts;
    integer late_addr_stall_cycles;
    integer late_addr_store_accepts;
    integer waw_raw_load_observations;
    integer waw_raw_mul_observations;
    integer waw_raw_transfer_opportunities;
    integer waw_raw_transfers;
    integer intra_rj_only;
    integer intra_rkd_only;
    integer intra_dual_source;
    integer intra_zero_dest_pairs;
    integer intra_same_rd_waw;
    integer intra_old_load_shadow;
    integer intra_old_mul_shadow;
    integer intra_streak;
    integer intra_max_streak;
    integer intra_redirects;
    integer intra_redirect_targets;
    integer intra_poison_fires;
    localparam logic [31:0] LATE_ADDR_TARGET = SCRATCH + 32'd32;
    localparam logic [31:0] LATE_ADDR_VALUE  = 32'h0000_05a5;

    // A store whose address source is still pending must remain in RF.  The
    // load-to-store-data exception applies only to rkd/store payload.
    wire late_addr_pending =
        u_cpu.u_RF.rf_valid &
        ((u_cpu.u_RF.db0.is_st & u_cpu.u_RF.rj_pending0) |
         (u_cpu.u_RF.idp.v1 & u_cpu.u_RF.db1.is_st &
          u_cpu.u_RF.rj_pending1));

    // The directed WAW->RAW program puts an unfinished slot0 load/MUL and a
    // ready slot1 ALU writer of the same register in EX1.  The RF consumer
    // must follow slot1, the youngest producer, instead of OR-ing slot0's
    // pending state into its dependency decision.
    wire waw_raw_ex1_shadow =
        u_cpu.u_RF.rf_valid &
        u_cpu.u_RF.db0.need_rj &
        (u_cpu.u_RF.rf_raddr1 != 5'b0) &
        u_cpu.ex1_fwd0.valid & u_cpu.ex1_fwd0.rf_we &
        ~u_cpu.ex1_fwd0.result_ready &
        (u_cpu.ex1_fwd0.rf_waddr == u_cpu.u_RF.rf_raddr1) &
        u_cpu.ex1_fwd1.valid & u_cpu.ex1_fwd1.rf_we &
        u_cpu.ex1_fwd1.result_ready &
        (u_cpu.ex1_fwd1.rf_waddr == u_cpu.u_RF.rf_raddr1);
    wire waw_raw_ex2_shadow =
        u_cpu.u_RF.rf_valid &
        u_cpu.u_RF.db0.need_rj &
        (u_cpu.u_RF.rf_raddr1 != 5'b0) &
        u_cpu.ex2_fwd0.valid & u_cpu.ex2_fwd0.rf_we &
        ~u_cpu.ex2_fwd0.result_ready &
        (u_cpu.ex2_fwd0.rf_waddr == u_cpu.u_RF.rf_raddr1) &
        u_cpu.ex2_fwd1.valid & u_cpu.ex2_fwd1.rf_we &
        u_cpu.ex2_fwd1.result_ready &
        (u_cpu.ex2_fwd1.rf_waddr == u_cpu.u_RF.rf_raddr1);
    wire waw_raw_shadow = waw_raw_ex1_shadow | waw_raw_ex2_shadow;
    wire waw_raw_load_shadow =
        (waw_raw_ex1_shadow & u_cpu.u_EX1.s0.is_ld) |
        (waw_raw_ex2_shadow & u_cpu.u_EX2.s0.is_mem);
    wire waw_raw_mul_shadow =
        (waw_raw_ex1_shadow & u_cpu.u_EX1.s0.is_mul) |
        (waw_raw_ex2_shadow & u_cpu.u_EX2.s0.is_mul);

    // The dedicated regression observes actual EX1 transfers, not just adjacent
    // instruction words.  This proves that the SLL->ADD/XOR contract reaches
    // the execute fast path with each source shape and under older WAW shadows.
    wire intra_ex1_transfer = u_cpu.u_EX1.ex1_fire &
                              u_cpu.u_EX1.ex1_r.v1;
    wire intra_dep_rj = u_cpu.u_EX1.ex1_r.s1_dep_rj_from_s0;
    wire intra_dep_rkd = u_cpu.u_EX1.ex1_r.s1_dep_rkd_from_s0;
    wire intra_fast_transfer = intra_ex1_transfer &
                               (intra_dep_rj | intra_dep_rkd);
    wire intra_zero_dest_transfer =
        intra_ex1_transfer &
        u_cpu.u_EX1.s0.alu_op[8] &
        (u_cpu.u_EX1.s0.rf_waddr == 5'b0) &
        (u_cpu.u_EX1.s1.alu_op[0] | u_cpu.u_EX1.s1.alu_op[7]) &
        ~(intra_dep_rj | intra_dep_rkd);

    wire intra_rf_bundle =
        u_cpu.u_RF.rf_valid & u_cpu.u_RF.idp.v1 &
        (u_cpu.u_RF.s1_dep_rj_from_s0 |
         u_cpu.u_RF.s1_dep_rkd_from_s0);
    wire [4:0] intra_rf_producer = u_cpu.u_RF.db0.rf_waddr;
    wire intra_old_ex1_s0 =
        intra_rf_bundle &
        (intra_rf_producer != 5'b0) &
        u_cpu.ex1_fwd0.valid & u_cpu.ex1_fwd0.rf_we &
        ~u_cpu.ex1_fwd0.result_ready &
        (u_cpu.ex1_fwd0.rf_waddr == intra_rf_producer);
    wire intra_old_ex2_s0 =
        intra_rf_bundle &
        (intra_rf_producer != 5'b0) &
        u_cpu.ex2_fwd0.valid & u_cpu.ex2_fwd0.rf_we &
        ~u_cpu.ex2_fwd0.result_ready &
        (u_cpu.ex2_fwd0.rf_waddr == intra_rf_producer);
    wire intra_old_load =
        (intra_old_ex1_s0 & u_cpu.u_EX1.s0.is_ld) |
        (intra_old_ex2_s0 & u_cpu.u_EX2.s0.is_mem);
    wire intra_old_mul =
        (intra_old_ex1_s0 & u_cpu.u_EX1.s0.is_mul) |
        (intra_old_ex2_s0 & u_cpu.u_EX2.s0.is_mul);

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
        if (!resetn) begin
            mul_accept_streak = 0;
            max_mul_accept_streak = 0;
            mul_turnovers = 0;
            late_data_matches = 0;
            late_data_direct_accepts = 0;
            late_data_capture_events = 0;
            late_data_retry_accepts = 0;
            late_addr_stall_cycles = 0;
            late_addr_store_accepts = 0;
            waw_raw_load_observations = 0;
            waw_raw_mul_observations = 0;
            waw_raw_transfer_opportunities = 0;
            waw_raw_transfers = 0;
            intra_rj_only = 0;
            intra_rkd_only = 0;
            intra_dual_source = 0;
            intra_zero_dest_pairs = 0;
            intra_same_rd_waw = 0;
            intra_old_load_shadow = 0;
            intra_old_mul_shadow = 0;
            intra_streak = 0;
            intra_max_streak = 0;
            intra_redirects = 0;
            intra_redirect_targets = 0;
            intra_poison_fires = 0;
        end else begin
            if (|debug_wb_rf_we)  check_commit(debug_wb_pc, debug_wb_rf_wnum, debug_wb_rf_wdata);
            if (|debug_wb1_rf_we) check_commit(debug_wb1_pc, debug_wb1_rf_wnum, debug_wb1_rf_wdata);
            // mul_in 与 mul_out 同拍握手表示 EX2 正在输出 M(n)，同时从
            // EX1 接收 M(n+1)。连续握手长度直接验证整核启动间隔为 1。
            if (u_cpu.u_EX2.mul_in_valid & u_cpu.u_EX2.mul_in_ready) begin
                mul_accept_streak = mul_accept_streak + 1;
                if (mul_accept_streak > max_mul_accept_streak)
                    max_mul_accept_streak = mul_accept_streak;
                if (u_cpu.u_EX2.mul_out_valid & u_cpu.u_EX2.mul_out_ready)
                    mul_turnovers = mul_turnovers + 1;
            end else begin
                mul_accept_streak = 0;
            end
            if ($test$plusargs("CHECK_LATE_BYPASS")) begin
                // Match+addr_ok is the cache-hit fast path.  Match without
                // addr_ok is the critical-word response that must be captured
                // while the refill tail keeps D-cache busy.
                if (u_cpu.u_EX1.ex1_valid &
                    u_cpu.u_EX1.late_store_pending &
                    u_cpu.u_EX1.late_store_match) begin
                    late_data_matches = late_data_matches + 1;
                    if (u_cpu.ex_data_sram_en & u_cpu.ex_data_addr_ok)
                        late_data_direct_accepts =
                            late_data_direct_accepts + 1;
                    else if (u_cpu.ex_data_sram_en &
                             ~u_cpu.ex_data_addr_ok)
                        late_data_capture_events =
                            late_data_capture_events + 1;
                    else begin
                        $display("  FAIL late store matched without a held request");
                        errors = errors + 1;
                    end
                end

                if (u_cpu.u_EX1.ex1_valid &
                    u_cpu.u_EX1.late_store_pending &
                    u_cpu.u_EX1.late_store_captured &
                    u_cpu.ex_data_sram_en & u_cpu.ex_data_addr_ok)
                    late_data_retry_accepts =
                        late_data_retry_accepts + 1;

                // This is stronger than checking the final address: it proves
                // the address-dependent store cannot leave RF while rj is
                // still produced by an unfinished load.
                if (late_addr_pending) begin
                    late_addr_stall_cycles = late_addr_stall_cycles + 1;
                    if (u_cpu.RF_to_EX1_valid) begin
                        $display("  FAIL address-dependent store left RF before load completion");
                        errors = errors + 1;
                    end
                end

                // The unique payload identifies the address-dependent store.
                // Require exactly one accepted request at its mapped target;
                // an early request using stale address zero is now observable.
                if (u_cpu.store_accept &
                    ((u_cpu.ex_data_sram_addr == LATE_ADDR_TARGET) |
                     (u_cpu.ex_data_sram_wdata == LATE_ADDR_VALUE))) begin
                    if ((u_cpu.ex_data_sram_addr != LATE_ADDR_TARGET) |
                        (u_cpu.ex_data_sram_wdata != LATE_ADDR_VALUE)) begin
                        $display("  FAIL address-dependent store addr=%08x data=%08x",
                                 u_cpu.ex_data_sram_addr,
                                 u_cpu.ex_data_sram_wdata);
                        errors = errors + 1;
                    end else begin
                        late_addr_store_accepts =
                            late_addr_store_accepts + 1;
                    end
                end
            end
            if ($test$plusargs("CHECK_WAW_RAW") && waw_raw_shadow) begin
                if (waw_raw_load_shadow)
                    waw_raw_load_observations =
                        waw_raw_load_observations + 1;
                if (waw_raw_mul_shadow)
                    waw_raw_mul_observations =
                        waw_raw_mul_observations + 1;
                if (u_cpu.u_RF.rf_dependency_stall) begin
                    $display("  FAIL younger ready WAW did not hide older pending producer");
                    errors = errors + 1;
                end
                if (u_cpu.EX1_allow_in) begin
                    waw_raw_transfer_opportunities =
                        waw_raw_transfer_opportunities + 1;
                    if (u_cpu.RF_to_EX1_valid)
                        waw_raw_transfers = waw_raw_transfers + 1;
                    else begin
                        $display("  FAIL WAW-shadowed consumer missed an EX1 transfer opportunity");
                        errors = errors + 1;
                    end
                end
            end
            if ($test$plusargs("CHECK_INTRA_RAW")) begin
                if ($test$plusargs("TRACE_INTRA_RAW") &
                    (intra_fast_transfer | intra_zero_dest_transfer))
                    $display("[INTRA EX1] pc=%08x/%08x rd=%0d/%0d dep=%0b/%0b",
                             u_cpu.u_EX1.s0.pc, u_cpu.u_EX1.s1.pc,
                             u_cpu.u_EX1.s0.rf_waddr,
                             u_cpu.u_EX1.s1.rf_waddr,
                             intra_dep_rj, intra_dep_rkd);
                if ($test$plusargs("TRACE_INTRA_RAW") & intra_rf_bundle)
                    $display("[INTRA RF] pc=%08x/%08x rd=%0d old=%0b load=%0b mul=%0b stall=%0b transfer=%0b",
                             u_cpu.u_RF.idp.s0.pc, u_cpu.u_RF.idp.s1.pc,
                             intra_rf_producer,
                             intra_old_ex1_s0 | intra_old_ex2_s0,
                             intra_old_load, intra_old_mul,
                             u_cpu.u_RF.rf_dependency_stall,
                             u_cpu.RF_to_EX1_valid & u_cpu.EX1_allow_in);
                if (intra_fast_transfer) begin
                    intra_streak = intra_streak + 1;
                    if (intra_streak > intra_max_streak)
                        intra_max_streak = intra_streak;
                    if (intra_dep_rj & intra_dep_rkd)
                        intra_dual_source = intra_dual_source + 1;
                    else if (intra_dep_rj)
                        intra_rj_only = intra_rj_only + 1;
                    else
                        intra_rkd_only = intra_rkd_only + 1;
                    if (u_cpu.u_EX1.s0.rf_waddr ==
                        u_cpu.u_EX1.s1.rf_waddr)
                        intra_same_rd_waw = intra_same_rd_waw + 1;
                    // r22 marks the first valid pair at the redirect target.
                    if (u_cpu.u_EX1.s0.rf_waddr == 5'd22)
                        intra_redirect_targets =
                            intra_redirect_targets + 1;
                end else begin
                    intra_streak = 0;
                end
                if (intra_zero_dest_transfer)
                    intra_zero_dest_pairs = intra_zero_dest_pairs + 1;
                // r29 is reserved for the wrong-path producer.  Count any
                // valid EX1 transfer, even if broken dependency metadata means
                // the pair no longer qualifies as the fast path.
                if (intra_ex1_transfer &
                    (u_cpu.u_EX1.s0.rf_waddr == 5'd29)) begin
                    intra_poison_fires = intra_poison_fires + 1;
                    $display("  FAIL wrong-path intra-RAW producer reached EX1");
                    errors = errors + 1;
                end
                if (u_cpu.redirect)
                    intra_redirects = intra_redirects + 1;

                if (intra_old_load) begin
                    intra_old_load_shadow = intra_old_load_shadow + 1;
                    if (u_cpu.u_RF.rf_dependency_stall) begin
                        $display("  FAIL older load blocked younger intra-RAW producer");
                        errors = errors + 1;
                    end
                end
                if (intra_old_mul) begin
                    intra_old_mul_shadow = intra_old_mul_shadow + 1;
                    if (u_cpu.u_RF.rf_dependency_stall) begin
                        $display("  FAIL older MUL blocked younger intra-RAW producer");
                        errors = errors + 1;
                    end
                end
            end
            if ($test$plusargs("trace_mem") && data_wr_req)
                $display("[STORE] pc0=%08x pc1=%08x v1=%0b addr=%08x we=%x data=%08x",
                         u_cpu.u_EX2.s0.pc, u_cpu.u_EX2.s1.pc, u_cpu.u_EX2.ex_v1_eff,
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

        // 读 meta: "ncommit nmem"
        fd = $fopen("golden.meta", "r");
        if (fd == 0)
            $fatal(1, "cannot open golden.meta");
        code = $fscanf(fd, "%d %d", ncommit, nmem);
        $fclose(fd);
        if (code != 2 || ncommit <= 0 || ncommit > MAXT ||
            nmem <= 0 || nmem > DEPTH)
            $fatal(1, "invalid golden.meta code=%0d commits=%0d mem=%0d",
                   code, ncommit, nmem);
        $readmemh("test.hex", base_mem);
        $readmemh("initial_mem.hex", ext_mem, idx(SCRATCH),
                  idx(SCRATCH) + nmem - 1);
        $readmemh("golden_mem.hex", g_mem, 0, nmem - 1);
        // 读提交流: 每行 "<pc> <wnum> <wdata>" (hex)
        fd = $fopen("golden_trace.hex", "r");
        if (fd == 0)
            $fatal(1, "cannot open golden_trace.hex");
        i = 0;
        code = $fscanf(fd, "%h %h %h", t_pc, t_wn, t_wd);
        while (code == 3 && i < MAXT) begin
            g_pc[i] = t_pc; g_wn[i] = t_wn; g_wd[i] = t_wd;
            i = i + 1;
            code = $fscanf(fd, "%h %h %h", t_pc, t_wn, t_wd);
        end
        $fclose(fd);
        if (i != ncommit) begin
            $fatal(1, "trace 行数 %0d 与 meta ncommit %0d 不符",
                   i, ncommit);
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
        if ($test$plusargs("CHECK_MUL_PIPE")) begin
            if (max_mul_accept_streak < 4 || mul_turnovers < 3) begin
                $display("  FAIL MUL pipeline streak=%0d turnovers=%0d, expected >=4/>=3",
                         max_mul_accept_streak, mul_turnovers);
                errors = errors + 1;
            end else begin
                $display("==== MUL PIPELINE PASSED: streak=%0d turnovers=%0d ====",
                         max_mul_accept_streak, mul_turnovers);
            end
        end
        if ($test$plusargs("CHECK_LATE_BYPASS")) begin
            if (late_data_matches < 2 ||
                late_data_direct_accepts < 1 ||
                late_data_capture_events < 1 ||
                late_data_retry_accepts < 1 ||
                late_addr_stall_cycles < 1 ||
                late_addr_store_accepts != 1) begin
                $display("  FAIL late bypass match/direct/capture/retry/addr_stall/addr_store=%0d/%0d/%0d/%0d/%0d/%0d",
                         late_data_matches, late_data_direct_accepts,
                         late_data_capture_events, late_data_retry_accepts,
                         late_addr_stall_cycles, late_addr_store_accepts);
                errors = errors + 1;
            end else begin
                $display("==== LATE BYPASS PASSED: match/direct/capture/retry/addr_stall/addr_store=%0d/%0d/%0d/%0d/%0d/%0d ====",
                         late_data_matches, late_data_direct_accepts,
                         late_data_capture_events, late_data_retry_accepts,
                         late_addr_stall_cycles, late_addr_store_accepts);
            end
        end
        if ($test$plusargs("CHECK_WAW_RAW")) begin
            if (($test$plusargs("EXPECT_WAW_LOAD") &&
                 (waw_raw_load_observations < 1)) ||
                ($test$plusargs("EXPECT_WAW_MUL") &&
                 (waw_raw_mul_observations < 1)) ||
                waw_raw_transfer_opportunities < 1 ||
                waw_raw_transfers != waw_raw_transfer_opportunities) begin
                $display("  FAIL WAW->RAW load/mul/opportunities/transfers=%0d/%0d/%0d/%0d",
                         waw_raw_load_observations,
                         waw_raw_mul_observations,
                         waw_raw_transfer_opportunities,
                         waw_raw_transfers);
                errors = errors + 1;
            end else begin
                $display("==== WAW->RAW PASSED: load/mul/opportunities/transfers=%0d/%0d/%0d/%0d ====",
                         waw_raw_load_observations,
                         waw_raw_mul_observations,
                         waw_raw_transfer_opportunities,
                         waw_raw_transfers);
            end
        end
        if ($test$plusargs("CHECK_INTRA_RAW")) begin
            if (intra_rj_only < 1 ||
                intra_rkd_only < 1 ||
                intra_dual_source < 1 ||
                intra_zero_dest_pairs < 1 ||
                intra_same_rd_waw < 1 ||
                intra_old_load_shadow < 1 ||
                intra_old_mul_shadow < 1 ||
                intra_max_streak < 3 ||
                intra_redirects < 1 ||
                intra_redirect_targets < 1 ||
                intra_poison_fires != 0) begin
                $display("  FAIL intra-RAW rj/rkd/dual/r0/waw/load/mul/streak/redirect/target/poison=%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d",
                         intra_rj_only, intra_rkd_only,
                         intra_dual_source, intra_zero_dest_pairs,
                         intra_same_rd_waw, intra_old_load_shadow,
                         intra_old_mul_shadow, intra_max_streak,
                         intra_redirects, intra_redirect_targets,
                         intra_poison_fires);
                errors = errors + 1;
            end else begin
                $display("==== INTRA-RAW PASSED: rj/rkd/dual/r0/waw/load/mul/streak/redirect/target=%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d ====",
                         intra_rj_only, intra_rkd_only,
                         intra_dual_source, intra_zero_dest_pairs,
                         intra_same_rd_waw, intra_old_load_shadow,
                         intra_old_mul_shadow, intra_max_streak,
                         intra_redirects, intra_redirect_targets);
            end
        end

        $display("==== checked: commits=%0d/%0d, mem=%0d words ====", tptr, ncommit, nmem);
        if (errors == 0) begin
            $display("==== RAND TEST PASSED ====");
            $finish;
        end else begin
            $fatal(1, "==== RAND TEST FAILED: %0d errors ====", errors);
        end
    end
endmodule
