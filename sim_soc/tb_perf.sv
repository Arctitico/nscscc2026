// ============================================================================
// 直连 SoC supervisor 性能测试
//
// 使用正式路线的 mycpu_top + mem_bridge + sram_ctrl，并固定 SRAM 为 2/2/1 拍。
// 测试镜像和入口由 plusarg 指定；通过真实 UART 向 supervisor 发送 G 命令。
// 0x06/0x07 计时标记之间统计 CPU 性能计数器、write-buffer occupancy 和直连
// SRAM 写通道活动，最后比较 ExtRAM 结果镜像。
// ============================================================================
module tb_perf;
    localparam integer RAM_WORDS    = 'h100000;
    localparam integer CLK_FREQ     = 90_000_000;
    localparam integer BAUD         = 115200;
    localparam integer CLKS_PER_BIT = (CLK_FREQ + BAUD / 2) / BAUD;

    reg clk;
    reg reset;
    reg rxd;
    wire txd;

    wire        inst_rd_req;
    wire [31:0] inst_rd_addr;
    wire        inst_rd_rdy;
    wire        inst_ret_valid;
    wire [31:0] inst_ret_data;
    wire        inst_ret_last;
    wire        data_rd_req;
    wire [ 2:0] data_rd_size;
    wire [31:0] data_rd_addr;
    wire [31:0] data_rd_data;
    wire        data_rd_ok;
    wire        data_wr_req;
    wire [ 2:0] data_wr_size;
    wire [31:0] data_wr_addr;
    wire [ 3:0] data_wr_strb;
    wire [31:0] data_wr_data;
    wire        data_wr_ok;

    wire [19:0] base_ram_addr;
    wire [ 3:0] base_ram_be_n;
    wire        base_ram_ce_n;
    wire        base_ram_oe_n;
    wire        base_ram_we_n;
    wire        base_ram_wdrive;
    wire [31:0] base_ram_wdat;
    wire [19:0] ext_ram_addr;
    wire [ 3:0] ext_ram_be_n;
    wire        ext_ram_ce_n;
    wire        ext_ram_oe_n;
    wire        ext_ram_we_n;
    wire        ext_ram_wdrive;
    wire [31:0] ext_ram_wdat;

    reg [31:0] base_mem   [0:RAM_WORDS-1];
    reg [31:0] ext_mem    [0:RAM_WORDS-1];
    reg [31:0] expect_mem [0:RAM_WORDS-1];

    wire [31:0] base_ram_rdat = base_mem[base_ram_addr];
    wire [31:0] ext_ram_rdat  = ext_mem[ext_ram_addr];

    mycpu_top u_cpu (
        .clk(clk), .resetn(~reset),
        .inst_rd_req(inst_rd_req), .inst_rd_addr(inst_rd_addr),
        .inst_rd_rdy(inst_rd_rdy), .inst_ret_valid(inst_ret_valid),
        .inst_ret_data(inst_ret_data), .inst_ret_last(inst_ret_last),
        .data_rd_req(data_rd_req), .data_rd_size(data_rd_size),
        .data_rd_addr(data_rd_addr), .data_rd_data(data_rd_data),
        .data_rd_ok(data_rd_ok),
        .data_wr_req(data_wr_req), .data_wr_size(data_wr_size),
        .data_wr_addr(data_wr_addr), .data_wr_strb(data_wr_strb),
        .data_wr_data(data_wr_data), .data_wr_ok(data_wr_ok),
        .debug_wb_pc(), .debug_wb_inst(), .debug_wb_rf_we(),
        .debug_wb_rf_wnum(), .debug_wb_rf_wdata(),
        .debug_wb1_pc(), .debug_wb1_inst(), .debug_wb1_rf_we(),
        .debug_wb1_rf_wnum(), .debug_wb1_rf_wdata()
    );

    mem_bridge #(
        .SRAM_READ_CYCLES(2),
        .SRAM_WRITE_CYCLES(2),
        .SRAM_WRITE_HOLD_CYCLES(1),
        .CLK_FREQ(CLK_FREQ)
    ) u_bridge (
        .clk(clk), .reset(reset),
        .inst_rd_req(inst_rd_req), .inst_rd_addr(inst_rd_addr),
        .inst_rd_rdy(inst_rd_rdy), .inst_ret_valid(inst_ret_valid),
        .inst_ret_data(inst_ret_data), .inst_ret_last(inst_ret_last),
        .data_rd_req(data_rd_req), .data_rd_size(data_rd_size),
        .data_rd_addr(data_rd_addr), .data_rd_data(data_rd_data),
        .data_rd_ok(data_rd_ok),
        .data_wr_req(data_wr_req), .data_wr_size(data_wr_size),
        .data_wr_addr(data_wr_addr), .data_wr_strb(data_wr_strb),
        .data_wr_data(data_wr_data), .data_wr_ok(data_wr_ok),
        .base_ram_addr(base_ram_addr), .base_ram_be_n(base_ram_be_n),
        .base_ram_ce_n(base_ram_ce_n), .base_ram_oe_n(base_ram_oe_n),
        .base_ram_we_n(base_ram_we_n), .base_ram_wdrive(base_ram_wdrive),
        .base_ram_wdat(base_ram_wdat), .base_ram_rdat(base_ram_rdat),
        .ext_ram_addr(ext_ram_addr), .ext_ram_be_n(ext_ram_be_n),
        .ext_ram_ce_n(ext_ram_ce_n), .ext_ram_oe_n(ext_ram_oe_n),
        .ext_ram_we_n(ext_ram_we_n), .ext_ram_wdrive(ext_ram_wdrive),
        .ext_ram_wdat(ext_ram_wdat), .ext_ram_rdat(ext_ram_rdat),
        .txd(txd), .rxd(rxd)
    );

    always @(posedge clk) begin
        if (~reset & ~base_ram_ce_n & ~base_ram_we_n) begin
            if (~base_ram_be_n[0]) base_mem[base_ram_addr][ 7: 0] <= base_ram_wdat[ 7: 0];
            if (~base_ram_be_n[1]) base_mem[base_ram_addr][15: 8] <= base_ram_wdat[15: 8];
            if (~base_ram_be_n[2]) base_mem[base_ram_addr][23:16] <= base_ram_wdat[23:16];
            if (~base_ram_be_n[3]) base_mem[base_ram_addr][31:24] <= base_ram_wdat[31:24];
        end
        if (~reset & ~ext_ram_ce_n & ~ext_ram_we_n) begin
            if (~ext_ram_be_n[0]) ext_mem[ext_ram_addr][ 7: 0] <= ext_ram_wdat[ 7: 0];
            if (~ext_ram_be_n[1]) ext_mem[ext_ram_addr][15: 8] <= ext_ram_wdat[15: 8];
            if (~ext_ram_be_n[2]) ext_mem[ext_ram_addr][23:16] <= ext_ram_wdat[23:16];
            if (~ext_ram_be_n[3]) ext_mem[ext_ram_addr][31:24] <= ext_ram_wdat[31:24];
        end
    end

    // ------------------------------ UART command/monitor -------------------
    task automatic send_byte(input [7:0] value);
        integer bit_index;
        begin
            rxd = 1'b0;
            repeat (CLKS_PER_BIT) @(posedge clk);
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                rxd = value[bit_index];
                repeat (CLKS_PER_BIT) @(posedge clk);
            end
            rxd = 1'b1;
            repeat (CLKS_PER_BIT) @(posedge clk);
        end
    endtask

    task automatic send_word(input [31:0] value);
        begin
            send_byte(value[ 7: 0]);
            send_byte(value[15: 8]);
            send_byte(value[23:16]);
            send_byte(value[31:24]);
        end
    endtask

    wire       mon_ready;
    wire [7:0] mon_data;
    reg        mon_clear;
    uart_rx #(.CLK_FREQ(CLK_FREQ), .BAUD(BAUD)) u_monitor_rx (
        .clk(clk), .reset(reset), .rxd(txd), .clear(mon_clear),
        .ready(mon_ready), .data(mon_data)
    );

    function automatic [7:0] expected_char(input integer index);
        case (index)
             0: expected_char = "M";  1: expected_char = "O";
             2: expected_char = "N";  3: expected_char = "I";
             4: expected_char = "T";  5: expected_char = "O";
             6: expected_char = "R";  7: expected_char = " ";
             8: expected_char = "f";  9: expected_char = "o";
            10: expected_char = "r"; 11: expected_char = " ";
            12: expected_char = "L"; 13: expected_char = "o";
            14: expected_char = "o"; 15: expected_char = "n";
            16: expected_char = "g"; 17: expected_char = "a";
            18: expected_char = "r"; 19: expected_char = "c";
            20: expected_char = "h"; 21: expected_char = "3";
            22: expected_char = "2"; 23: expected_char = " ";
            24: expected_char = "-"; 25: expected_char = " ";
            26: expected_char = "i"; 27: expected_char = "n";
            28: expected_char = "i"; 29: expected_char = "t";
            30: expected_char = "i"; 31: expected_char = "a";
            32: expected_char = "l"; 33: expected_char = "i";
            34: expected_char = "z"; 35: expected_char = "e";
            36: expected_char = "d"; 37: expected_char = ".";
            default: expected_char = 8'h00;
        endcase
    endfunction

    integer welcome_pos;
    reg welcome_done;
    always @(posedge clk) begin
        if (reset) begin
            mon_clear   <= 1'b0;
            welcome_pos <= 0;
            welcome_done <= 1'b0;
        end else begin
            mon_clear <= mon_ready;
            if (mon_ready & ~mon_clear & ~welcome_done) begin
                if (mon_data == expected_char(welcome_pos)) begin
                    if (welcome_pos == 37)
                        welcome_done <= 1'b1;
                    else
                        welcome_pos <= welcome_pos + 1;
                end else begin
                    welcome_pos <= (mon_data == "M") ? 1 : 0;
                end
            end
        end
    end

    // ------------------------------ performance counters ------------------
    reg counting;
    reg finished;
    reg [63:0] start_cycle;
    reg [63:0] end_cycle;
    reg [63:0] start_wb_stall;
    reg [63:0] end_wb_stall;
    reg [63:0] occ0_cycles;
    reg [63:0] occ1_cycles;
    reg [63:0] occ2_cycles;
    reg [63:0] push_count;
    reg [63:0] pop_count;
    reg [63:0] same_line_push;
    reg [63:0] same_word_push;
    reg [63:0] data_wr_req_cycles;
    reg [63:0] data_wr_done_count;
    reg [63:0] ext_write_active_cycles;
    reg        prev_push_valid;
    reg [31:0] prev_push_addr;
    reg [63:0] ic_miss_count;
    reg [63:0] ic_miss_next;
    reg [63:0] ic_miss_same;
    reg [63:0] ic_miss_other;
    reg [63:0] ic_miss_from_seq;
    reg [63:0] ic_miss_from_pred;
    reg [63:0] ic_miss_from_other;
    reg [63:0] if_seq_cross;
    reg [63:0] if_pred_cross;
    reg [63:0] postfill_next;
    reg [63:0] postfill_next_lt8;
    reg [63:0] postfill_next_ge8;
    reg [63:0] inst_wait_cycles;
    reg [63:0] inst_wait_data_cycles;
    reg [63:0] base_idle_cycles;
    reg [63:0] base_inst_cycles;
    reg [63:0] base_data_read_cycles;
    reg [63:0] base_data_write_cycles;
    reg        prev_miss_valid;
    reg [31:0] prev_miss_line;
    reg        prev_if_expected_valid;
    reg        prev_if_expected_pred;
    reg [31:0] prev_if_expected_line;
    reg [ 1:0] accepted_if_origin;
    reg [31:0] active_fill_line;
    reg        last_fill_valid;
    reg [31:0] last_fill_line;
    reg [63:0] last_fill_cycle;

    wire wb_push = u_cpu.u_dcache.u_write_buffer.push;
    wire wb_pop  = u_cpu.u_dcache.u_write_buffer.pop;
    wire [1:0] wb_count = u_cpu.u_dcache.u_write_buffer.count;
    wire marker_start = u_bridge.u_uart.tx_start &
                        (u_bridge.u_uart.tx_data == 8'h06);
    wire marker_end = u_bridge.u_uart.tx_start &
                      (u_bridge.u_uart.tx_data == 8'h07);
    wire ic_miss_event = u_cpu.perf_icache_miss_event;
    wire [31:0] ic_miss_line = {u_cpu.u_icache.inst_rd_addr[31:4], 4'b0};
    wire if_f1_fire = u_cpu.u_IF.f1_fire;
    wire if_selected_pred = u_cpu.bp_taken0 |
                            (u_cpu.u_IF.want_s1 & u_cpu.bp_taken1);
    wire [31:0] if_next_pc = u_cpu.u_IF.next_pc;
    localparam [1:0] IF_ORIGIN_OTHER = 2'd0;
    localparam [1:0] IF_ORIGIN_SEQ   = 2'd1;
    localparam [1:0] IF_ORIGIN_PRED  = 2'd2;

    always @(posedge clk) begin
        if (reset) begin
            counting               <= 1'b0;
            finished               <= 1'b0;
            start_cycle            <= 64'b0;
            end_cycle              <= 64'b0;
            start_wb_stall         <= 64'b0;
            end_wb_stall           <= 64'b0;
            occ0_cycles            <= 64'b0;
            occ1_cycles            <= 64'b0;
            occ2_cycles            <= 64'b0;
            push_count             <= 64'b0;
            pop_count              <= 64'b0;
            same_line_push         <= 64'b0;
            same_word_push         <= 64'b0;
            data_wr_req_cycles     <= 64'b0;
            data_wr_done_count     <= 64'b0;
            ext_write_active_cycles <= 64'b0;
            prev_push_valid        <= 1'b0;
            prev_push_addr         <= 32'b0;
            prev_miss_valid        <= 1'b0;
            prev_if_expected_valid <= 1'b0;
            accepted_if_origin     <= IF_ORIGIN_OTHER;
            last_fill_valid        <= 1'b0;
        end else if (marker_start) begin
            counting               <= 1'b1;
            start_cycle            <= u_cpu.perf_cycle;
            start_wb_stall         <= u_cpu.perf_wb_stall;
            occ0_cycles            <= 64'b0;
            occ1_cycles            <= 64'b0;
            occ2_cycles            <= 64'b0;
            push_count             <= 64'b0;
            pop_count              <= 64'b0;
            same_line_push         <= 64'b0;
            same_word_push         <= 64'b0;
            data_wr_req_cycles     <= 64'b0;
            data_wr_done_count     <= 64'b0;
            ext_write_active_cycles <= 64'b0;
            prev_push_valid        <= 1'b0;
            ic_miss_count          <= 64'b0;
            ic_miss_next           <= 64'b0;
            ic_miss_same           <= 64'b0;
            ic_miss_other          <= 64'b0;
            ic_miss_from_seq       <= 64'b0;
            ic_miss_from_pred      <= 64'b0;
            ic_miss_from_other     <= 64'b0;
            if_seq_cross           <= 64'b0;
            if_pred_cross          <= 64'b0;
            postfill_next          <= 64'b0;
            postfill_next_lt8      <= 64'b0;
            postfill_next_ge8      <= 64'b0;
            inst_wait_cycles      <= 64'b0;
            inst_wait_data_cycles <= 64'b0;
            base_idle_cycles      <= 64'b0;
            base_inst_cycles      <= 64'b0;
            base_data_read_cycles <= 64'b0;
            base_data_write_cycles <= 64'b0;
            prev_miss_valid        <= 1'b0;
            prev_if_expected_valid <= 1'b0;
            accepted_if_origin     <= IF_ORIGIN_OTHER;
            last_fill_valid        <= 1'b0;
        end else if (marker_end & counting) begin
            counting       <= 1'b0;
            finished       <= 1'b1;
            end_cycle      <= u_cpu.perf_cycle;
            end_wb_stall   <= u_cpu.perf_wb_stall;
        end else if (counting) begin
            case (wb_count)
            2'd0: occ0_cycles <= occ0_cycles + 64'd1;
            2'd1: occ1_cycles <= occ1_cycles + 64'd1;
            default: occ2_cycles <= occ2_cycles + 64'd1;
            endcase
            if (wb_push) begin
                push_count <= push_count + 64'd1;
                if (prev_push_valid &
                    (prev_push_addr[31:4] == u_cpu.u_dcache.req_addr[31:4]))
                    same_line_push <= same_line_push + 64'd1;
                if (prev_push_valid &
                    (prev_push_addr[31:2] == u_cpu.u_dcache.req_addr[31:2]))
                    same_word_push <= same_word_push + 64'd1;
                prev_push_valid <= 1'b1;
                prev_push_addr  <= u_cpu.u_dcache.req_addr;
            end
            if (wb_pop)
                pop_count <= pop_count + 64'd1;
            if (data_wr_req)
                data_wr_req_cycles <= data_wr_req_cycles + 64'd1;
            if (data_wr_req & data_wr_ok)
                data_wr_done_count <= data_wr_done_count + 64'd1;
            if ((u_bridge.u_ext.state != 1'b0) & u_bridge.u_ext.write_r)
                ext_write_active_cycles <= ext_write_active_cycles + 64'd1;

            if (!u_bridge.base_busy)
                base_idle_cycles <= base_idle_cycles + 64'd1;
            else if (!u_bridge.u_base.tag_out)
                base_inst_cycles <= base_inst_cycles + 64'd1;
            else if (u_bridge.u_base.write_r)
                base_data_write_cycles <= base_data_write_cycles + 64'd1;
            else
                base_data_read_cycles <= base_data_read_cycles + 64'd1;

            if (inst_rd_req & inst_rd_rdy)
                active_fill_line <= inst_rd_addr;
            if (inst_rd_req & ~inst_rd_rdy) begin
                inst_wait_cycles <= inst_wait_cycles + 64'd1;
                if (u_bridge.base_pick_data)
                    inst_wait_data_cycles <= inst_wait_data_cycles + 64'd1;
            end
            if (inst_ret_valid & inst_ret_last) begin
                last_fill_valid <= 1'b1;
                last_fill_line  <= active_fill_line;
                last_fill_cycle <= u_cpu.perf_cycle;
            end

            if (if_f1_fire) begin
                if (prev_if_expected_valid &&
                    ({u_cpu.bp_pc0[31:4], 4'b0} == prev_if_expected_line))
                    accepted_if_origin <= prev_if_expected_pred ?
                                          IF_ORIGIN_PRED : IF_ORIGIN_SEQ;
                else
                    accepted_if_origin <= IF_ORIGIN_OTHER;
                if (if_next_pc[31:4] != u_cpu.bp_pc0[31:4]) begin
                    if (if_selected_pred)
                        if_pred_cross <= if_pred_cross + 64'd1;
                    else
                        if_seq_cross <= if_seq_cross + 64'd1;
                end
                prev_if_expected_valid <= 1'b1;
                prev_if_expected_pred  <= if_selected_pred;
                prev_if_expected_line  <= {if_next_pc[31:4], 4'b0};
            end

            if (ic_miss_event) begin
                ic_miss_count <= ic_miss_count + 64'd1;
                case (accepted_if_origin)
                IF_ORIGIN_SEQ:
                    ic_miss_from_seq <= ic_miss_from_seq + 64'd1;
                IF_ORIGIN_PRED:
                    ic_miss_from_pred <= ic_miss_from_pred + 64'd1;
                default:
                    ic_miss_from_other <= ic_miss_from_other + 64'd1;
                endcase
                if (prev_miss_valid) begin
                    if (ic_miss_line == prev_miss_line + 32'd16)
                        ic_miss_next <= ic_miss_next + 64'd1;
                    else if (ic_miss_line == prev_miss_line)
                        ic_miss_same <= ic_miss_same + 64'd1;
                    else
                        ic_miss_other <= ic_miss_other + 64'd1;
                end
                if (last_fill_valid &&
                    (ic_miss_line == last_fill_line + 32'd16)) begin
                    postfill_next <= postfill_next + 64'd1;
                    if ((u_cpu.perf_cycle - last_fill_cycle) < 64'd8)
                        postfill_next_lt8 <= postfill_next_lt8 + 64'd1;
                    else
                        postfill_next_ge8 <= postfill_next_ge8 + 64'd1;
                end
                prev_miss_valid <= 1'b1;
                prev_miss_line  <= ic_miss_line;
            end
        end
    end

    // ------------------------------ image loading/check --------------------
    string kernel_hex;
    string base_extra_hex;
    string ext_hex;
    string expected_hex;
    integer base_extra_start;
    integer expected_start;
    integer expected_words;
    integer entry;
    integer max_cycles;
    integer i;
    integer mismatches;

    initial clk = 1'b0;
    always #5 clk = ~clk;

    initial begin
        if (!$value$plusargs("kernel_hex=%s", kernel_hex))
            $fatal(1, "missing +kernel_hex");
        if (!$value$plusargs("expected_hex=%s", expected_hex))
            $fatal(1, "missing +expected_hex");
        if (!$value$plusargs("expected_start=%h", expected_start))
            $fatal(1, "missing +expected_start");
        if (!$value$plusargs("expected_words=%d", expected_words))
            $fatal(1, "missing +expected_words");
        if (!$value$plusargs("entry=%h", entry))
            $fatal(1, "missing +entry");
        if (!$value$plusargs("max_cycles=%d", max_cycles))
            max_cycles = 100_000_000;

        for (i = 0; i < RAM_WORDS; i = i + 1) begin
            base_mem[i]   = 32'b0;
            ext_mem[i]    = 32'b0;
            expect_mem[i] = 32'b0;
        end
        $readmemh(kernel_hex, base_mem);
        if ($value$plusargs("base_extra_hex=%s", base_extra_hex)) begin
            if (!$value$plusargs("base_extra_start=%h", base_extra_start))
                $fatal(1, "missing +base_extra_start");
            $readmemh(base_extra_hex, base_mem, base_extra_start);
        end
        if ($value$plusargs("ext_hex=%s", ext_hex))
            $readmemh(ext_hex, ext_mem);
        $readmemh(expected_hex, expect_mem);

        rxd   = 1'b1;
        reset = 1'b1;
        repeat (8) @(posedge clk);
        reset = 1'b0;

        wait (welcome_done);
        $display("[DIRECT PERF] send G %08x", entry);
        send_byte("G");
        send_word(entry);
    end

    initial begin
        wait (~reset);
        repeat (max_cycles) @(posedge clk);
        if (!finished)
            $fatal(1, "DIRECT PERF TIMEOUT after %0d cycles", max_cycles);
    end

    initial begin
        wait (finished);
        @(posedge clk);
        mismatches = 0;
        for (i = 0; i < expected_words; i = i + 1) begin
            if (ext_mem[expected_start + i] !== expect_mem[i]) begin
                if (mismatches < 8)
                    $display("[DIRECT PERF] mismatch word %0d: got=%08x expected=%08x",
                             i, ext_mem[expected_start + i], expect_mem[i]);
                mismatches = mismatches + 1;
            end
        end
        $display("[DIRECT PERF] cycles=%0d wb_stall=%0d",
                 end_cycle - start_cycle, end_wb_stall - start_wb_stall);
        $display("[DIRECT PERF] push=%0d pop=%0d same_line=%0d same_word=%0d",
                 push_count, pop_count, same_line_push, same_word_push);
        $display("[DIRECT PERF] occ0=%0d occ1=%0d occ2=%0d",
                 occ0_cycles, occ1_cycles, occ2_cycles);
        $display("[DIRECT PERF] wr_req_cycles=%0d wr_done=%0d ext_write_active=%0d",
                 data_wr_req_cycles, data_wr_done_count, ext_write_active_cycles);
        $display("[PREFETCH] miss=%0d next=%0d same=%0d other=%0d",
                 ic_miss_count, ic_miss_next, ic_miss_same, ic_miss_other);
        $display("[PREFETCH] miss_origin seq=%0d pred=%0d other=%0d cross seq=%0d pred=%0d",
                 ic_miss_from_seq, ic_miss_from_pred, ic_miss_from_other,
                 if_seq_cross, if_pred_cross);
        $display("[PREFETCH] postfill_next=%0d lt8=%0d ge8=%0d inst_wait=%0d wait_data=%0d",
                 postfill_next, postfill_next_lt8, postfill_next_ge8,
                 inst_wait_cycles, inst_wait_data_cycles);
        $display("[PREFETCH] base idle=%0d inst=%0d data_read=%0d data_write=%0d",
                 base_idle_cycles, base_inst_cycles,
                 base_data_read_cycles, base_data_write_cycles);
        if (mismatches != 0)
            $fatal(1, "DIRECT PERF FAILED: %0d result mismatches", mismatches);
        $display("==== DIRECT PERF PASSED ====");
        $finish;
    end
endmodule
