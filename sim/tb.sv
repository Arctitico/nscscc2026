// ============================================================================
// tb.sv —— mycpu_top 功能仿真平台（verilator --binary）
// 行为级内存：类 SRAM 组合读（同周期），写在时钟沿按字节使能写。
// 指令与数据共用一块内存（程序 0x80000000 起，数据 0x80100000 起）。
// 自检：捕获每次提交的寄存器写，运行结束后比对期望值。
// ============================================================================
module tb;
    localparam logic [31:0] BASE  = 32'h8000_0000;
    localparam int          DEPTH = 'h42000;          // 覆盖到 0x80108000

    reg clk, resetn;

    wire        inst_sram_en;
    wire [ 3:0] inst_sram_we;
    wire [31:0] inst_sram_addr, inst_sram_wdata;
    wire [31:0] inst_sram_rdata;

    wire        data_sram_en;
    wire [ 3:0] data_sram_we;
    wire [31:0] data_sram_addr, data_sram_wdata;
    wire [31:0] data_sram_rdata;

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

    // ---- 行为级内存 ----
    reg [31:0] mem [0:DEPTH-1];

    function automatic int idx(input [31:0] addr);
        idx = (addr - BASE) >> 2;
    endfunction
    function automatic bit inrange(input [31:0] addr);
        inrange = (addr >= BASE) && (idx(addr) < DEPTH);
    endfunction

    // 组合读
    assign inst_sram_rdata = inrange(inst_sram_addr) ? mem[idx(inst_sram_addr)] : 32'h0;
    assign data_sram_rdata = inrange(data_sram_addr) ? mem[idx(data_sram_addr)] : 32'h0;

    // 写（时钟沿，按字节使能）
    always @(posedge clk) begin
        if (data_sram_en && (|data_sram_we) && inrange(data_sram_addr)) begin
            if (data_sram_we[0]) mem[idx(data_sram_addr)][ 7: 0] <= data_sram_wdata[ 7: 0];
            if (data_sram_we[1]) mem[idx(data_sram_addr)][15: 8] <= data_sram_wdata[15: 8];
            if (data_sram_we[2]) mem[idx(data_sram_addr)][23:16] <= data_sram_wdata[23:16];
            if (data_sram_we[3]) mem[idx(data_sram_addr)][31:24] <= data_sram_wdata[31:24];
        end
    end

    // ---- 提交捕获 ----
    reg [31:0] arch [0:31];
    integer i;
    integer commits;

    always @(posedge clk) begin
        if (resetn && (|debug_wb_rf_we)) begin
            arch[debug_wb_rf_wnum] <= debug_wb_rf_wdata;
            commits <= commits + 1;
            if (commits < 80)
                $display("[commit %0d] pc=%08x  r%0d <= %08x",
                         commits, debug_wb_pc, debug_wb_rf_wnum, debug_wb_rf_wdata);
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
        if (mem[idx(addr)] !== exp) begin
            $display("  FAIL mem[%08x] = %08x, expected %08x", addr, mem[idx(addr)], exp);
            errors = errors + 1;
        end else
            $display("  ok   mem[%08x] = %08x", addr, mem[idx(addr)]);
    endtask

    initial begin
        for (i = 0; i < DEPTH; i = i + 1) mem[i] = 32'h0;
        for (i = 0; i < 32;    i = i + 1) arch[i] = 32'hx;
        commits = 0; errors = 0;
        $readmemh("test.hex", mem);

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
        checkmem(32'h80100000, 32'd55);
        checkmem(32'h80100004, 32'h000000ff);
        checkmem(32'h80100008, 32'h21);

        if (errors == 0) $display("==== TEST PASSED ====");
        else             $display("==== TEST FAILED: %0d errors ====", errors);
        $finish;
    end
endmodule
