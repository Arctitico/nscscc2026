// ============================================================================
// 2026 supervisor 启动回归
//
// 加载自动 CPUCFG/cache 探测版 kernel，等待 115200 UART 欢迎字符串。直接例化
// mycpu_top + mem_bridge，绕开 Verilator 对板级 inout 首拍的解析伪迹；SRAM 控制器、
// 地址译码、UART 寄存器和物理串行收发仍走真实 RTL。
// ============================================================================
module tb_supervisor;
    localparam int RAM_WORDS = 'h100000; // 每片 4 MiB

    reg clk;
    reg reset;

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
    wire [31:0] debug_wb_pc;
    wire [ 3:0] debug_wb_rf_we;
    wire [ 4:0] debug_wb_rf_wnum;
    wire [31:0] debug_wb_rf_wdata;
    wire [31:0] debug_wb1_pc;
    wire [ 3:0] debug_wb1_rf_we;
    wire [ 4:0] debug_wb1_rf_wnum;
    wire [31:0] debug_wb1_rf_wdata;

    wire [19:0] base_ram_addr;
    wire [ 3:0] base_ram_be_n;
    wire        base_ram_ce_n;
    wire        base_ram_oe_n;
    wire        base_ram_we_n;
    wire [31:0] base_ram_wdat;
    wire [19:0] ext_ram_addr;
    wire [ 3:0] ext_ram_be_n;
    wire        ext_ram_ce_n;
    wire        ext_ram_oe_n;
    wire        ext_ram_we_n;
    wire [31:0] ext_ram_wdat;
    wire        txd;

    reg [31:0] base_mem [0:RAM_WORDS-1];
    reg [31:0] ext_mem  [0:RAM_WORDS-1];

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
        .debug_wb_pc(debug_wb_pc), .debug_wb_inst(), .debug_wb_rf_we(debug_wb_rf_we),
        .debug_wb_rf_wnum(debug_wb_rf_wnum), .debug_wb_rf_wdata(debug_wb_rf_wdata),
        .debug_wb1_pc(debug_wb1_pc), .debug_wb1_inst(), .debug_wb1_rf_we(debug_wb1_rf_we),
        .debug_wb1_rf_wnum(debug_wb1_rf_wnum), .debug_wb1_rf_wdata(debug_wb1_rf_wdata)
    );

    mem_bridge #(.SRAM_LATENCY(2)) u_bridge (
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
        .base_ram_we_n(base_ram_we_n), .base_ram_wdat(base_ram_wdat),
        .base_ram_rdat(base_ram_rdat),
        .ext_ram_addr(ext_ram_addr), .ext_ram_be_n(ext_ram_be_n),
        .ext_ram_ce_n(ext_ram_ce_n), .ext_ram_oe_n(ext_ram_oe_n),
        .ext_ram_we_n(ext_ram_we_n), .ext_ram_wdat(ext_ram_wdat),
        .ext_ram_rdat(ext_ram_rdat),
        .txd(txd), .rxd(1'b1)
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

    // 用同一官方 async_receiver 解码 DUT 的 115200 串行输出。
    wire       mon_ready;
    wire [7:0] mon_data;
    async_receiver #(.ClkFrequency(50_000_000), .Baud(115200)) u_monitor_rx (
        .clk(clk), .RxD(txd), .RxD_data_ready(mon_ready),
        .RxD_clear(mon_ready), .RxD_data(mon_data)
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

    integer msg_pos;
    integer commit_count;
    integer fetch_count;
    integer refill_count;
    always @(posedge clk) begin
        if (reset) begin
            fetch_count <= 0;
            refill_count <= 0;
        end else if (u_cpu.IF_to_ID_valid && u_cpu.ID_allow_in) begin
            if ($test$plusargs("trace_boot") && fetch_count < 12)
                $display("[fetch %0d] pc0=%08x inst0=%08x v1=%0b pc1=%08x inst1=%08x", fetch_count,
                         u_cpu.IF_to_ID_BUS.s0.pc, u_cpu.IF_to_ID_BUS.s0.inst,
                         u_cpu.IF_to_ID_BUS.v1,
                         u_cpu.IF_to_ID_BUS.s1.pc, u_cpu.IF_to_ID_BUS.s1.inst);
            fetch_count <= fetch_count + 1 + u_cpu.IF_to_ID_BUS.v1;
        end
        if (!reset && inst_ret_valid && refill_count < 12) begin
            if ($test$plusargs("trace_boot"))
            $display("[refill %0d] ram_addr=%05x data=%08x last=%0b",
                     refill_count, base_ram_addr, inst_ret_data, inst_ret_last);
            refill_count <= refill_count + 1;
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            commit_count <= 0;
        end else begin
            if ((|debug_wb_rf_we) && $test$plusargs("trace_boot") && commit_count < 80)
                $display("[boot %0d] pc=%08x r%0d<=%08x", commit_count,
                         debug_wb_pc, debug_wb_rf_wnum, debug_wb_rf_wdata);
            if ((|debug_wb1_rf_we) && $test$plusargs("trace_boot") && commit_count < 80)
                $display("[boot %0d#] pc=%08x r%0d<=%08x", commit_count,
                         debug_wb1_pc, debug_wb1_rf_wnum, debug_wb1_rf_wdata);
            commit_count <= commit_count + (|debug_wb_rf_we) + (|debug_wb1_rf_we);
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            msg_pos <= 0;
        end else if (mon_ready) begin
            if (mon_data == expected_char(msg_pos)) begin
                if (msg_pos == 37) begin
                    $display("==== SUPERVISOR BOOT PASSED ====");
                    $finish;
                end
                msg_pos <= msg_pos + 1;
            end else begin
                $display("UART mismatch at %0d: got %02x expected %02x",
                         msg_pos, mon_data, expected_char(msg_pos));
                msg_pos <= (mon_data == "M") ? 1 : 0;
            end
        end
    end

    initial clk = 1'b0;
    always #10 clk = ~clk; // 50 MHz

    integer i;
    initial begin
        for (i = 0; i < RAM_WORDS; i = i + 1) begin
            base_mem[i] = 32'b0;
            ext_mem[i]  = 32'b0;
        end
        $readmemh("kernel.hex", base_mem);

        reset = 1'b1;
        repeat (8) @(posedge clk);
        reset = 1'b0;

        repeat (10_000_000) @(posedge clk);
        $display("==== SUPERVISOR BOOT TIMEOUT (matched %0d/38 chars, commits=%0d) ====",
                 msg_pos, commit_count);
        $finish;
    end
endmodule
