`timescale 1ns/1ps
import cpu_pkg::*;

module tb_dcache_mshr;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg reset = 1'b1;
    reg flush;
    rob_idx_t recover_idx;
    rob_idx_t rob_head_idx;
    reg cpu_req;
    reg [3:0] cpu_we;
    reg [2:0] cpu_size;
    reg [31:0] cpu_addr;
    reg [31:0] cpu_wdata;
    ex_wb_slot_t cpu_meta;
    wire cpu_addr_ok;
    wire [31:0] cpu_rdata;
    wire cpu_data_ok;
    ex_wb_slot_t cpu_resp_meta;

    wire mem_rd_req;
    wire [2:0] mem_rd_size;
    wire [31:0] mem_rd_addr;
    wire [31:0] mem_rdata;
    wire mem_rd_ok;
    wire mem_wr_req;
    wire perf_hit_under_miss;
    wire perf_secondary_merge;

    dcache u_dut (
        .clk(clk), .reset(reset),
        .flush(flush), .recover_idx(recover_idx),
        .rob_head_idx(rob_head_idx),
        .cpu_req(cpu_req), .cpu_we(cpu_we), .cpu_size(cpu_size),
        .cpu_addr(cpu_addr), .cpu_wdata(cpu_wdata), .cpu_meta(cpu_meta),
        .cpu_addr_ok(cpu_addr_ok), .cpu_rdata(cpu_rdata),
        .cpu_data_ok(cpu_data_ok), .cpu_resp_meta(cpu_resp_meta),
        .mem_rd_req(mem_rd_req), .mem_rd_size(mem_rd_size),
        .mem_rd_addr(mem_rd_addr), .mem_rdata(mem_rdata),
        .mem_rd_ok(mem_rd_ok),
        .mem_wr_req(mem_wr_req), .mem_wr_size(), .mem_wr_addr(),
        .mem_wr_strb(), .mem_wr_data(), .mem_wr_ok(1'b0),
        .inst_safe(), .perf_hit(), .perf_miss(), .perf_wb_stall(),
        .perf_hit_under_miss(perf_hit_under_miss),
        .perf_secondary_merge(perf_secondary_merge),
        .perf_independent_miss_busy(), .perf_mshr_full_stall(),
        .perf_refill_tail()
    );

    // 每个 line 请求先等待 5 拍，再连续返回 4 个 word。
    reg rd_active;
    reg [2:0] rd_delay;
    reg [1:0] rd_beat;
    reg [31:0] rd_base;
    assign mem_rd_ok = rd_active & (rd_delay == 3'd0);
    assign mem_rdata = (rd_base + {28'b0, rd_beat, 2'b00})
                      ^ 32'h5a5a_0000;

    always_ff @(posedge clk) begin
        if (reset) begin
            rd_active <= 1'b0;
            rd_delay  <= '0;
            rd_beat   <= '0;
        end else if (!rd_active) begin
            if (mem_rd_req) begin
                rd_active <= 1'b1;
                rd_delay  <= 3'd5;
                rd_beat   <= 2'd0;
                rd_base   <= mem_rd_addr;
            end
        end else if (rd_delay != 3'd0) begin
            rd_delay <= rd_delay - 3'd1;
        end else if (rd_beat == 2'd3) begin
            rd_active <= 1'b0;
        end else begin
            rd_beat <= rd_beat + 2'd1;
        end
    end

    task automatic send_load(input [31:0] addr,
                             input preg_t pdst,
                             input rob_idx_t rob_idx);
        @(negedge clk);
        cpu_req = 1'b1;
        cpu_addr = addr;
        cpu_we = 4'b0;
        cpu_size = 3'b010;
        cpu_meta = '0;
        cpu_meta.pc = {24'b0, pdst, 2'b0};
        cpu_meta.rf_we = 1'b1;
        cpu_meta.rf_wdata_sel = 2'b01;
        cpu_meta.ld_width = 4'b1111;
        cpu_meta.pdst = pdst;
        cpu_meta.rob_idx = rob_idx;
        do
            @(posedge clk);
        while (!cpu_addr_ok);
        @(negedge clk);
        cpu_req = 1'b0;
    endtask

    integer errors;
    reg seen_warm_b;
    reg seen_a0;
    reg seen_a2;
    reg seen_b_under_miss;
    reg seen_c_older;
    reg seen_c_younger;
    integer hit_under_miss_count;
    integer secondary_merge_count;

    always_ff @(posedge clk) begin
        if (reset) begin
            errors <= 0;
            seen_warm_b <= 1'b0;
            seen_a0 <= 1'b0;
            seen_a2 <= 1'b0;
            seen_b_under_miss <= 1'b0;
            seen_c_older <= 1'b0;
            seen_c_younger <= 1'b0;
            hit_under_miss_count <= 0;
            secondary_merge_count <= 0;
        end else begin
        if (perf_hit_under_miss)
            hit_under_miss_count <= hit_under_miss_count + 1;
        if (perf_secondary_merge)
            secondary_merge_count <= secondary_merge_count + 1;
        if (cpu_data_ok) begin
            $display("resp pdst=%0d data=%08x a0=%0d t=%0t",
                     cpu_resp_meta.pdst, cpu_rdata, seen_a0, $time);
            case (cpu_resp_meta.pdst)
            preg_t'(6'd32): begin
                if (cpu_rdata !== (32'h1c40_0020 ^ 32'h5a5a_0000))
                    errors <= errors + 1;
                seen_warm_b <= 1'b1;
            end
            preg_t'(6'd33): begin
                if (cpu_rdata !== (32'h1c40_0000 ^ 32'h5a5a_0000))
                    errors <= errors + 1;
                seen_a0 <= 1'b1;
            end
            preg_t'(6'd34): begin
                if (cpu_rdata !== (32'h1c40_0008 ^ 32'h5a5a_0000))
                    errors <= errors + 1;
                seen_a2 <= 1'b1;
            end
            preg_t'(6'd35): begin
                if (cpu_rdata !== (32'h1c40_0020 ^ 32'h5a5a_0000))
                    errors <= errors + 1;
                // B 必须在 A primary 返回前完成，才是真 hit-under-miss。
                if (seen_a0)
                    errors <= errors + 1;
                seen_b_under_miss <= 1'b1;
            end
            preg_t'(6'd36): begin
                if (cpu_rdata !== (32'h1c40_0040 ^ 32'h5a5a_0000))
                    errors <= errors + 1;
                seen_c_older <= 1'b1;
            end
            preg_t'(6'd37): begin
                // recover_idx=2 时 rob3 是年轻请求，不得产生响应。
                seen_c_younger <= 1'b1;
                errors <= errors + 1;
            end
            default:
                errors <= errors + 1;
            endcase
        end
        end
    end

    initial begin
        cpu_req = 1'b0;
        cpu_we = 4'b0;
        cpu_size = 3'b010;
        cpu_addr = 32'b0;
        cpu_wdata = 32'b0;
        cpu_meta = '0;
        flush = 1'b0;
        recover_idx = '0;
        rob_head_idx = '0;
        repeat (4) @(posedge clk);
        reset = 1'b0;

        // 先把 B line 预热。
        send_load(32'h1c40_0020, preg_t'(32), rob_idx_t'(0));
        wait (seen_warm_b);

        // A0 冷 miss；A2 合并到同一 MSHR；B0 应在 A 返回前命中。
        send_load(32'h1c40_0000, preg_t'(33), rob_idx_t'(1));
        send_load(32'h1c40_0008, preg_t'(34), rob_idx_t'(2));
        send_load(32'h1c40_0020, preg_t'(35), rob_idx_t'(3));

        wait (seen_a0 && seen_a2 && seen_b_under_miss);

        // C line 两个 waiter 分处恢复点两侧，只保留更老的 rob1。
        send_load(32'h1c40_0040, preg_t'(36), rob_idx_t'(1));
        send_load(32'h1c40_0044, preg_t'(37), rob_idx_t'(3));
        @(negedge clk);
        recover_idx = rob_idx_t'(2);
        rob_head_idx = rob_idx_t'(0);
        flush = 1'b1;
        @(negedge clk);
        flush = 1'b0;

        repeat (80) @(posedge clk);
        if ((errors == 0) && seen_a0 && seen_a2 && seen_b_under_miss &&
            seen_c_older && !seen_c_younger &&
            (hit_under_miss_count != 0) && (secondary_merge_count != 0))
            $display("==== DCACHE MSHR TEST PASSED ====");
        else begin
            $display("seen warm=%0d a0=%0d a2=%0d b_hum=%0d hum=%0d merge=%0d",
                     seen_warm_b, seen_a0, seen_a2, seen_b_under_miss,
                     hit_under_miss_count, secondary_merge_count);
            $display("==== DCACHE MSHR TEST FAILED: %0d errors ====", errors);
        end
        $finish;
    end
endmodule
