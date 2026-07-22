// ============================================================================
// tb.sv —— mycpu_top 功能仿真平台（verilator --binary）
// 行为级内存：类 SRAM 组合读（同周期），写在时钟沿按字节使能写。
// 行为级 BaseRAM/ExtRAM：程序从 0x1c000000 取指，数据放在 0x1c400000。
// 自检：捕获每次提交的寄存器写，运行结束后比对期望值。
// ============================================================================
module tb;
    localparam int DEPTH = 'h10000; // 本定向回归只需每片 RAM 的低 256 KiB

    reg clk, resetn;

    wire        inst_rd_req;
    wire [31:0] inst_rd_addr;
    wire        inst_rd_rdy, inst_ret_valid, inst_ret_last;
    wire [31:0] inst_ret_data;

    wire        data_sram_en;
    wire [ 3:0] data_sram_we;
    wire [31:0] data_sram_addr, data_sram_wdata;
    wire [31:0] data_sram_rdata;

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
        .data_sram_en(data_sram_en), .data_sram_we(data_sram_we),
        .data_sram_size(),
        .data_sram_addr(data_sram_addr), .data_sram_wdata(data_sram_wdata),
        .data_sram_rdata(data_sram_rdata), .data_ok(1'b1),
        .debug_wb_pc(debug_wb_pc), .debug_wb_inst(), .debug_wb_rf_we(debug_wb_rf_we),
        .debug_wb_rf_wnum(debug_wb_rf_wnum), .debug_wb_rf_wdata(debug_wb_rf_wdata),
        .debug_wb1_pc(debug_wb1_pc), .debug_wb1_inst(), .debug_wb1_rf_we(debug_wb1_rf_we),
        .debug_wb1_rf_wnum(debug_wb1_rf_wnum), .debug_wb1_rf_wdata(debug_wb1_rf_wdata)
    );

    // ---- 行为级内存 ----
    reg [31:0] base_mem [0:DEPTH-1];
    reg [31:0] ext_mem  [0:DEPTH-1];

    function automatic int idx(input [31:0] addr); idx = addr[21:2]; endfunction
    function automatic bit is_base(input [31:0] addr);
        is_base = (addr[31:22] == 10'h070) && (idx(addr) < DEPTH);
    endfunction
    function automatic bit is_ext(input [31:0] addr);
        is_ext = (addr[31:22] == 10'h071) && (idx(addr) < DEPTH);
    endfunction

    // 数据口：组合读
    assign data_sram_rdata = is_base(data_sram_addr) ? base_mem[idx(data_sram_addr)] :
                             is_ext(data_sram_addr)  ? ext_mem[idx(data_sram_addr)]  : 32'h0;

    // 取指口：行为级突发读模型（接受当拍 rd_rdy，随后逐拍回 IWORDS 个字）
    localparam int IWORDS = 4;
    reg        iactive;
    reg [ 2:0] iw;
    reg [31:0] ibase;
    wire        iaccept       = inst_rd_req & ~iactive;
    wire [31:0] ibeat_addr    = ibase + (iw << 2);
    assign inst_rd_rdy    = iaccept;
    assign inst_ret_valid = iactive;
    assign inst_ret_data  = is_base(ibeat_addr) ? base_mem[idx(ibeat_addr)] :
                            is_ext(ibeat_addr)  ? ext_mem[idx(ibeat_addr)]  : 32'h0;
    assign inst_ret_last  = iactive & (iw == IWORDS-1);
    always @(posedge clk) begin
        if (!resetn)        begin iactive <= 1'b0; iw <= 3'd0; end
        else if (iaccept)   begin iactive <= 1'b1; iw <= 3'd0; ibase <= inst_rd_addr; end
        else if (iactive) begin
            iw <= iw + 3'd1;
            if (iw == IWORDS-1) iactive <= 1'b0;
        end
    end

    // 写（时钟沿，按字节使能）
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

    // ---- 提交捕获 ----
    reg [31:0] arch [0:31];
    integer i;
    integer commits;

    always @(posedge clk) begin
        if (resetn) begin
            if (|debug_wb_rf_we) begin
                arch[debug_wb_rf_wnum] <= debug_wb_rf_wdata;
                if (commits < 80)
                    $display("[commit %0d] pc=%08x  r%0d <= %08x",
                             commits, debug_wb_pc, debug_wb_rf_wnum, debug_wb_rf_wdata);
            end
            if (|debug_wb1_rf_we) begin
                arch[debug_wb1_rf_wnum] <= debug_wb1_rf_wdata;
                if (commits < 80)
                    $display("[commit %0d#] pc=%08x  r%0d <= %08x",
                             commits, debug_wb1_pc, debug_wb1_rf_wnum, debug_wb1_rf_wdata);
            end
            commits <= commits + (|debug_wb_rf_we) + (|debug_wb1_rf_we);
        end
    end

    // ---- 时钟 ----
    initial clk = 0;
    always #5 clk = ~clk;

    // ---- 自检 ----
    integer errors;
    task check(input [4:0] r, input [31:0] exp);
        if (arch[r] !== exp) begin
            $display("  FAIL r%0d = %08x, expected %08x", r, arch[r], exp);
            errors = errors + 1;
        end else
            $display("  ok   r%0d = %08x", r, arch[r]);
    endtask
    task checkmem(input [31:0] addr, input [31:0] exp);
        if (ext_mem[idx(addr)] !== exp) begin
            $display("  FAIL mem[%08x] = %08x, expected %08x", addr, ext_mem[idx(addr)], exp);
            errors = errors + 1;
        end else
            $display("  ok   mem[%08x] = %08x", addr, ext_mem[idx(addr)]);
    endtask

    initial begin
        for (i = 0; i < DEPTH; i = i + 1) begin base_mem[i] = 32'h0; ext_mem[i] = 32'h0; end
        for (i = 0; i < 32;    i = i + 1) arch[i] = 32'hx;
        commits = 0; errors = 0;
        $readmemh("test.hex", base_mem);

        resetn = 0;
        repeat (4) @(posedge clk);
        resetn = 1;

        repeat (800) @(posedge clk);

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
        check(5'd22, 32'h0);
        check(5'd24, 32'h1);
        check(5'd27, 32'd96);
        check(5'd28, 32'hffff_fffb);
        checkmem(32'h1c400000, 32'd55);
        checkmem(32'h1c400004, 32'h000000ff);
        checkmem(32'h1c400008, 32'h21);
        checkmem(32'h1c40000c, 32'hffff_fffb);

        if (errors == 0) $display("==== TEST PASSED ====");
        else             $display("==== TEST FAILED: %0d errors ====", errors);
        $finish;
    end
endmodule
