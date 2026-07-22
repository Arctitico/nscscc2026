// ============================================================================
// Instruction Fetch：F1 发出对齐 8 字节的取指请求，F2 向 ID 交付 1~2 条指令。
// 若起始 PC 为 8B 块内的第二个字，或 slot0 预测跳转，则只交付 slot0。
// ============================================================================
import cpu_pkg::*;

module IF (
    input  wire             clk,
    input  wire             reset,

    output wire             IF_to_ID_valid,
    input  wire             ID_allow_in,
    output if_to_id_bus_t   IF_to_ID_BUS,

    output wire   [31:0]    bp_pc0,
    input  wire             bp_taken0,
    input  wire   [31:0]    bp_target0,
    input  wire             bp_taken1,
    input  wire   [31:0]    bp_target1,

    // 误预测重定向
    input  wire             redirect,
    input  wire   [31:0]    redirect_target,

    output wire             ic_req,
    output wire   [31:0]    ic_addr,
    input  wire             ic_addr_ok,
    input  wire             ic_data_ok,
    input  wire   [31:0]    ic_rdata_lo,
    input  wire   [31:0]    ic_rdata_hi
);

localparam [31:0] RESET_PC = 32'h1c00_0000;
wire flush = redirect;

// pre-IF (F1)
reg [31:0] pc_f1;
reg        valid_f1;

assign bp_pc0  = pc_f1;
assign ic_addr = pc_f1;

wire        odd_start = pc_f1[2];
wire        want_s1   = ~odd_start & ~bp_taken0;
wire [31:0] next_pc   = bp_taken0             ? bp_target0
                      : (want_s1 & bp_taken1) ? bp_target1
                      : odd_start             ? (pc_f1 + 32'd4)
                                              : (pc_f1 + 32'd8);

// IF (F2)
reg [31:0] pc0_f2;
reg        v1_f2;
reg        odd_f2;
reg        bp_taken0_f2;
reg [31:0] bp_target0_f2;
reg        bp_taken1_f2;
reg [31:0] bp_target1_f2;
reg        valid_f2;

// 指令到了但本拍没交付出去则缓存
reg        inst_valid_f2;
reg [31:0] inst0_f2;
reg [31:0] inst1_f2;

wire data_here   = valid_f2 & ic_data_ok;
wire f2_ready_go = data_here | inst_valid_f2;
wire f2_allowin  = ~valid_f2 | (f2_ready_go & ID_allow_in);

assign ic_req  = valid_f1 & f2_allowin & ~flush;
wire   f1_fire = ic_req & ic_addr_ok;

assign IF_to_ID_valid = valid_f2 & f2_ready_go & ~flush;
wire   f2_fire        = IF_to_ID_valid & ID_allow_in;

wire [31:0] raw_inst0   = odd_f2 ? ic_rdata_hi : ic_rdata_lo;
wire [31:0] raw_inst1   = ic_rdata_hi;
wire [31:0] inst0_to_id = inst_valid_f2 ? inst0_f2 : raw_inst0;
wire [31:0] inst1_to_id = inst_valid_f2 ? inst1_f2 : raw_inst1;

assign IF_to_ID_BUS = '{
    s0: '{pc: pc0_f2,         inst: inst0_to_id,
          bp_taken: bp_taken0_f2, bp_target: bp_target0_f2},
    s1: '{pc: pc0_f2 + 32'd4, inst: inst1_to_id,
          bp_taken: bp_taken1_f2, bp_target: bp_target1_f2},
    v1: v1_f2
};

always @(posedge clk) begin
    if (reset) valid_f1 <= 1'b0;
    else       valid_f1 <= 1'b1;
end

always @(posedge clk) begin
    if (reset)        pc_f1 <= RESET_PC;
    else if (flush)   pc_f1 <= redirect_target;
    else if (f1_fire) pc_f1 <= next_pc;
end

always @(posedge clk) begin
    if (reset | flush) valid_f2 <= 1'b0;
    else if (f1_fire)  valid_f2 <= 1'b1;
    else if (f2_fire)  valid_f2 <= 1'b0;
end

always @(posedge clk) begin
    if (f1_fire) begin
        pc0_f2        <= pc_f1;
        v1_f2         <= want_s1;
        odd_f2        <= odd_start;
        bp_taken0_f2  <= bp_taken0;
        bp_target0_f2 <= bp_target0;
        bp_taken1_f2  <= bp_taken1;
        bp_target1_f2 <= bp_target1;
    end
end

always @(posedge clk) begin
    if (reset | flush)             inst_valid_f2 <= 1'b0;
    else if (f1_fire)              inst_valid_f2 <= 1'b0;
    else if (data_here & ~f2_fire) inst_valid_f2 <= 1'b1;
    else if (f2_fire)              inst_valid_f2 <= 1'b0;
end

always @(posedge clk) begin
    if (data_here & ~f2_fire) begin
        inst0_f2 <= raw_inst0;
        inst1_f2 <= raw_inst1;
    end
end

endmodule
