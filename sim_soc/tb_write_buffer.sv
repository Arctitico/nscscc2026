`timescale 1ns/1ps

module tb_write_buffer;

reg         clk;
reg         reset;
reg         enq_valid;
wire        enq_ready;
reg  [31:0] enq_addr;
reg  [ 2:0] enq_size;
reg  [ 3:0] enq_strb;
reg  [31:0] enq_data;
wire        mem_req;
wire [31:0] mem_addr;
wire [ 2:0] mem_size;
wire [ 3:0] mem_strb;
wire [31:0] mem_data;
reg         mem_done;
wire        empty;
reg  [31:0] query_addr;
wire        line_conflict;
reg  [31:0] chip_query_addr;
wire        chip_conflict;

write_buffer dut (
    .clk(clk),
    .reset(reset),
    .enq_valid(enq_valid),
    .enq_ready(enq_ready),
    .enq_addr(enq_addr),
    .enq_size(enq_size),
    .enq_strb(enq_strb),
    .enq_data(enq_data),
    .mem_req(mem_req),
    .mem_addr(mem_addr),
    .mem_size(mem_size),
    .mem_strb(mem_strb),
    .mem_data(mem_data),
    .mem_done(mem_done),
    .empty(empty),
    .query_addr(query_addr),
    .line_conflict(line_conflict),
    .chip_query_addr(chip_query_addr),
    .chip_conflict(chip_conflict)
);

reg [31:0] model_addr [0:255];
reg [ 2:0] model_size [0:255];
reg [ 3:0] model_strb [0:255];
reg [31:0] model_data [0:255];
integer model_head;
integer model_tail;
integer model_count;
integer errors;
integer cycles;

always #5 clk = ~clk;

task automatic check(input condition, input string message);
begin
    if (condition !== 1'b1) begin
        $display("FAIL cycle=%0d: %s", cycles, message);
        errors = errors + 1;
    end
end
endtask

task automatic check_state;
    integer index;
    reg [3:0] expected_valid;
begin
    expected_valid = 4'b0;
    for (index = 0; index < model_count; index = index + 1)
        expected_valid[(model_head + index) % 4] = 1'b1;

    check(dut.count === model_count[2:0], "count mismatch");
    check(dut.rd_ptr === model_head[1:0], "rd_ptr mismatch");
    check(dut.wr_ptr === model_tail[1:0], "wr_ptr mismatch");
    check(dut.valid === expected_valid, "valid mask mismatch");
    check(empty === (model_count == 0), "empty mismatch");
    check(mem_req === (model_count != 0), "mem_req mismatch");

    if (model_count != 0) begin
        check(mem_addr === model_addr[model_head], "head address mismatch");
        check(mem_size === model_size[model_head], "head size mismatch");
        check(mem_strb === model_strb[model_head], "head strobe mismatch");
        check(mem_data === model_data[model_head], "head data mismatch");
    end
end
endtask

task automatic cycle(
    input        request_push,
    input [31:0] push_addr,
    input [ 2:0] push_size,
    input [ 3:0] push_strb,
    input [31:0] push_data,
    input        request_pop
);
    reg expected_pop;
    reg expected_ready;
    reg expected_push;
begin
    @(negedge clk);
    enq_valid = request_push;
    enq_addr  = push_addr;
    enq_size  = push_size;
    enq_strb  = push_strb;
    enq_data  = push_data;
    mem_done  = request_pop;
    #1;

    expected_pop   = (model_count != 0) && request_pop;
    expected_ready = (model_count != 4) || expected_pop;
    expected_push  = request_push && expected_ready;

    check(enq_ready === expected_ready, "pre-edge enq_ready mismatch");
    check_state();

    @(posedge clk);
    #1;
    cycles = cycles + 1;

    if (expected_pop) begin
        model_head = model_head + 1;
        model_count = model_count - 1;
    end
    if (expected_push) begin
        model_addr[model_tail] = push_addr;
        model_size[model_tail] = push_size;
        model_strb[model_tail] = push_strb;
        model_data[model_tail] = push_data;
        model_tail = model_tail + 1;
        model_count = model_count + 1;
    end

    check_state();
end
endtask

task automatic check_query(
    input [31:0] line_address,
    input [31:0] chip_address,
    input        expected_line,
    input        expected_chip
);
begin
    @(negedge clk);
    enq_valid = 1'b0;
    mem_done = 1'b0;
    query_addr = line_address;
    chip_query_addr = chip_address;
    #1;
    check(line_conflict === expected_line, "line_conflict mismatch");
    check(chip_conflict === expected_chip, "chip_conflict mismatch");
    check_state();
end
endtask

localparam [31:0] A = 32'h1c00_0010;
localparam [31:0] B = 32'h1c40_0020;
localparam [31:0] C = 32'h1c00_0030;
localparam [31:0] D = 32'h1c40_0040;
localparam [31:0] E = 32'h1c00_0050;
localparam [31:0] F = 32'h1c40_0060;
localparam [31:0] G = 32'h1c00_0070;
localparam [31:0] H = 32'h1c40_0080;

integer i;
initial begin
    clk = 1'b0;
    reset = 1'b1;
    enq_valid = 1'b0;
    enq_addr = 32'b0;
    enq_size = 3'b0;
    enq_strb = 4'b0;
    enq_data = 32'b0;
    mem_done = 1'b0;
    query_addr = 32'b0;
    chip_query_addr = 32'b0;
    model_head = 0;
    model_tail = 0;
    model_count = 0;
    errors = 0;
    cycles = 0;

    repeat (3) @(posedge clk);
    @(negedge clk);
    reset = 1'b0;
    #1;
    check_state();

    // Fill all four physical slots with alternating SRAM chips.
    cycle(1, A, 3'b010, 4'b1111, 32'haaaa_0001, 0);
    cycle(1, B, 3'b001, 4'b0011, 32'hbbbb_0002, 0);
    cycle(1, C, 3'b000, 4'b0100, 32'hcccc_0003, 0);
    cycle(1, D, 3'b010, 4'b1000, 32'hdddd_0004, 0);

    check_query(A, A, 1, 1);
    check_query(B, B, 1, 1);
    check_query(C, A, 1, 1);
    check_query(D, B, 1, 1);
    check_query(32'h1c00_0ff0, A, 0, 1);
    check_query(32'h1c40_0ff0, B, 0, 1);

    // A fifth entry cannot enter a full, non-popping FIFO. Head is stable.
    cycle(1, F, 3'b111, 4'b1111, 32'hffff_dead, 0);
    cycle(1, G, 3'b110, 4'b0001, 32'h7777_dead, 0);

    // Full turnover: old A is consumed and E replaces the same physical slot.
    cycle(1, E, 3'b011, 4'b1111, 32'heeee_0005, 1);
    check_query(A, A, 0, 1);
    check_query(E, A, 1, 1);

    // Exercise independent pop and non-full simultaneous pop+push.
    cycle(0, 32'b0, 3'b0, 4'b0, 32'b0, 1);
    cycle(1, F, 3'b100, 4'b0010, 32'hffff_0006, 1);
    cycle(0, 32'b0, 3'b0, 4'b0, 32'b0, 1);
    cycle(0, 32'b0, 3'b0, 4'b0, 32'b0, 1);

    // One-entry turnover uses different read/write slots and keeps count at one.
    check_query(F, B, 1, 1);
    cycle(1, G, 3'b101, 4'b0101, 32'h7777_0007, 1);
    check_query(G, A, 1, 1);
    cycle(0, 32'b0, 3'b0, 4'b0, 32'b0, 1);
    check_query(A, A, 0, 0);
    check_query(B, B, 0, 0);

    // mem_done while empty is ignored; enqueue remains available.
    cycle(0, 32'b0, 3'b0, 4'b0, 32'b0, 1);

    // Same-address stores emerge in original order with all payload fields.
    cycle(1, H, 3'b000, 4'b0001, 32'h1111_1111, 0);
    check_query(H, B, 1, 1);
    cycle(1, H, 3'b001, 4'b0010, 32'h2222_2222, 0);
    cycle(1, H, 3'b010, 4'b1100, 32'h3333_3333, 0);
    cycle(0, 32'b0, 3'b0, 4'b0, 32'b0, 1);
    cycle(0, 32'b0, 3'b0, 4'b0, 32'b0, 1);
    cycle(0, 32'b0, 3'b0, 4'b0, 32'b0, 1);

    // Repeated enqueue/dequeue wraps both pointers multiple additional times.
    for (i = 0; i < 12; i = i + 1) begin
        cycle(1, 32'h1c00_1000 + i * 16, i[2:0],
              4'b0001 << (i % 4), 32'h9000_0000 + i, 0);
        cycle(0, 32'b0, 3'b0, 4'b0, 32'b0, 1);
    end

    check_query(32'h1c00_1000, A, 0, 0);
    check_query(32'h1c40_1000, B, 0, 0);

    if (errors == 0)
        $display("PASS: 4-entry write buffer FIFO/conflict tests (%0d cycles)",
                 cycles);
    else
        $display("FAIL: %0d write-buffer errors", errors);

    if (errors != 0)
        $fatal(1);
    $finish;
end

endmodule
