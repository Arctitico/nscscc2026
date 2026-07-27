module tb_selfmod;
    localparam int DEPTH = 'h1000;
    localparam [31:0] STORE_PC   = 32'h1c00_0028;
    localparam [31:0] TARGET_PC  = 32'h1c00_0080;
    localparam [31:0] NEW_TARGET = 32'h0284_8c0b;
    localparam int TARGET_WORD = 'h20;
    localparam int TARGET_BTB_INDEX = 'h20;

    reg clk_50M;
    reg reset_btn;
    reg rxd;
    wire txd;

    wire [31:0] base_ram_data, ext_ram_data;
    wire [19:0] base_ram_addr, ext_ram_addr;
    wire [3:0] base_ram_be_n, ext_ram_be_n;
    wire base_ram_ce_n, base_ram_oe_n, base_ram_we_n;
    wire ext_ram_ce_n, ext_ram_oe_n, ext_ram_we_n;
    wire [15:0] leds;
    wire [7:0] dpy0, dpy1;
    wire [2:0] video_red, video_green;
    wire [1:0] video_blue;
    wire video_hsync, video_vsync, video_clk, video_de;

    thinpad_top #(
        .SIMULATION               (1),
        .CPU_CLK_HZ               (50_000_000),
        .SRAM_READ_CYCLES         (3),
        .SRAM_WRITE_CYCLES        (3),
        .SRAM_WRITE_HOLD_CYCLES   (1)
    ) u_dut (
        .clk(clk_50M), .reset(reset_btn),
        .touch_btn(4'b0), .dip_sw(32'b0),
        .leds(leds), .dpy0(dpy0), .dpy1(dpy1),
        .base_ram_data(base_ram_data), .base_ram_addr(base_ram_addr),
        .base_ram_be_n(base_ram_be_n), .base_ram_ce_n(base_ram_ce_n),
        .base_ram_oe_n(base_ram_oe_n), .base_ram_we_n(base_ram_we_n),
        .ext_ram_data(ext_ram_data), .ext_ram_addr(ext_ram_addr),
        .ext_ram_be_n(ext_ram_be_n), .ext_ram_ce_n(ext_ram_ce_n),
        .ext_ram_oe_n(ext_ram_oe_n), .ext_ram_we_n(ext_ram_we_n),
        .UART_TX(txd), .UART_RX(rxd),
        .video_red(video_red), .video_green(video_green),
        .video_blue(video_blue), .video_hsync(video_hsync),
        .video_vsync(video_vsync), .video_clk(video_clk),
        .video_de(video_de)
    );

    reg [31:0] base_mem [0:DEPTH-1];
    reg [31:0] ext_mem [0:DEPTH-1];

    assign base_ram_data = (~base_ram_ce_n & ~base_ram_oe_n & base_ram_we_n)
                         ? base_mem[base_ram_addr] : 32'bz;
    assign ext_ram_data = (~ext_ram_ce_n & ~ext_ram_oe_n & ext_ram_we_n)
                        ? ext_mem[ext_ram_addr] : 32'bz;

    integer target_writes;
    always @(posedge clk_50M) begin
        if (~reset_btn & ~base_ram_ce_n & ~base_ram_we_n) begin
            if (~base_ram_be_n[0])
                base_mem[base_ram_addr][7:0] <= u_dut.base_ram_wdat[7:0];
            if (~base_ram_be_n[1])
                base_mem[base_ram_addr][15:8] <= u_dut.base_ram_wdat[15:8];
            if (~base_ram_be_n[2])
                base_mem[base_ram_addr][23:16] <= u_dut.base_ram_wdat[23:16];
            if (~base_ram_be_n[3])
                base_mem[base_ram_addr][31:24] <= u_dut.base_ram_wdat[31:24];
            if (base_ram_addr == TARGET_WORD)
                target_writes <= target_writes + 1;
        end
        if (~reset_btn & ~ext_ram_ce_n & ~ext_ram_we_n) begin
            if (~ext_ram_be_n[0])
                ext_mem[ext_ram_addr][7:0] <= u_dut.ext_ram_wdat[7:0];
            if (~ext_ram_be_n[1])
                ext_mem[ext_ram_addr][15:8] <= u_dut.ext_ram_wdat[15:8];
            if (~ext_ram_be_n[2])
                ext_mem[ext_ram_addr][23:16] <= u_dut.ext_ram_wdat[23:16];
            if (~ext_ram_be_n[3])
                ext_mem[ext_ram_addr][31:24] <= u_dut.ext_ram_wdat[31:24];
        end
    end

    integer selfmod_hits;
    integer selfmod_flushes;
    integer slot1_commits;
    reg started;

    always @(posedge clk_50M) begin
        if (started && u_dut.u_cpu.selfmod_hit) begin
            selfmod_hits <= selfmod_hits + 1;
            if (u_dut.u_cpu.ex_data_sram_pc != STORE_PC)
                $fatal(1, "selfmod hit attributed to wrong store PC");
            if (!u_dut.u_cpu.u_EX1.ex1_r.v1)
                $fatal(1, "directed store did not coissue with slot1");
            if (!u_dut.u_cpu.u_EX2.mul_in_valid)
                $fatal(1, "killed slot1 MUL was not launched speculatively");
            if (!u_dut.u_cpu.u_bpu.btb_valid[TARGET_BTB_INDEX])
                $fatal(1, "target branch was not present in BTB before clear");
        end

        if (started && u_dut.u_cpu.selfmod_flush) begin
            selfmod_flushes <= selfmod_flushes + 1;
            if (!u_dut.u_cpu.u_EX2.ex2_valid ||
                u_dut.u_cpu.u_EX2.ex2_r.s0.pc != STORE_PC)
                $fatal(1, "triggering store was cleared before EX2 completed");
            if (u_dut.u_cpu.u_EX2.ex2_r.v1)
                $fatal(1, "selfmod store failed to kill same-bundle slot1");
            if (!u_dut.u_cpu.u_EX2.u_mul.out_valid ||
                !u_dut.u_cpu.u_EX2.mul_out_ready ||
                u_dut.u_cpu.u_EX2.ex2_has_mul)
                $fatal(1, "killed slot1 MUL token was not discarded in EX2");
            #1;
            if (u_dut.u_cpu.u_bpu.btb_valid != '0)
                $fatal(1, "selfmod flush did not clear the BTB");
            if (u_dut.u_cpu.u_icache.valid0 != '0 ||
                u_dut.u_cpu.u_icache.valid1 != '0)
                $fatal(1, "selfmod flush did not clear both I-cache ways");
        end

        if (started && |u_dut.u_cpu.debug_wb_rf_we &&
            u_dut.u_cpu.debug_wb_pc == STORE_PC + 32'd4)
            slot1_commits <= slot1_commits + 1;
        if (started && |u_dut.u_cpu.debug_wb1_rf_we &&
            u_dut.u_cpu.debug_wb1_pc == STORE_PC + 32'd4)
            slot1_commits <= slot1_commits + 1;
    end

    initial clk_50M = 1'b0;
    always #5 clk_50M = ~clk_50M;

    integer i;
    integer cycles;
    initial begin
        for (i = 0; i < DEPTH; i = i + 1) begin
            base_mem[i] = 32'b0;
            ext_mem[i] = 32'b0;
        end
        $readmemh("selfmod.hex", base_mem);

        reset_btn = 1'b1;
        rxd = 1'b1;
        target_writes = 0;
        selfmod_hits = 0;
        selfmod_flushes = 0;
        slot1_commits = 0;
        started = 1'b0;

        repeat (8) @(posedge clk_50M);
        reset_btn = 1'b0;
        started = 1'b1;

        cycles = 0;
        while (ext_mem[4] != 32'h55 && cycles < 20000) begin
            @(posedge clk_50M);
            cycles = cycles + 1;
        end
        repeat (100) @(posedge clk_50M);

        if (cycles >= 20000)
            $fatal(1, "selfmod program timed out");
        if (base_mem[TARGET_WORD] != NEW_TARGET)
            $fatal(1, "physical code store did not update BaseRAM");
        if (ext_mem[0] != 32'd2 || ext_mem[1] != 32'h123 ||
            ext_mem[2] != 32'd9 || ext_mem[3] != 32'd1)
            $fatal(1, "architectural result mismatch: %h %h %h %h",
                   ext_mem[0], ext_mem[1], ext_mem[2], ext_mem[3]);
        if (selfmod_hits != 1 || selfmod_flushes != 1)
            $fatal(1, "expected one selfmod event/flush, got %0d/%0d",
                   selfmod_hits, selfmod_flushes);
        if (slot1_commits != 1)
            $fatal(1, "store slot1 committed %0d times, expected exactly once",
                   slot1_commits);
        // SRAM 控制器会把一次写事务的 WE 保持多个周期；这里只要求确实
        // 发生物理写，CPU 侧 store 接受次数已由 selfmod_hits==1 约束。
        if (target_writes == 0)
            $fatal(1, "target instruction was never physically written");

        $display("CPU SELFMOD REFETCH TEST PASSED (%0d cycles)", cycles);
        $finish;
    end
endmodule
