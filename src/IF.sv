// ============================================================================
// Instruction Fetch
// 分为两个阶段, pre-IF（F1）和 IF（F2)，
// F1 负责产生访存地址并发出请求，F2 负责接收指令并交付给 ID
// ============================================================================
module IF (
    input  wire             clk,
    input  wire             reset,

    output wire             IF_to_ID_valid,
    input  wire             ID_allow_in,
    output if_to_id_bus_t   IF_to_ID_BUS,

    // 分支预测（来自 bpu）
    output wire   [31:0]    bp_pc,
    input  wire             bp_taken,
    input  wire   [31:0]    bp_target,

    // 误预测重定向（来自 EX）
    input  wire             redirect,
    input  wire   [31:0]    redirect_target,

    // icache
    output wire             ic_req,
    output wire   [31:0]    ic_addr,
    input  wire             ic_addr_ok,
    input  wire             ic_data_ok,
    input  wire   [31:0]    ic_rdata
);

localparam [31:0] RESET_PC = 32'h1c00_0000;

wire flush = redirect;

// pre-IF. 记为 F1
reg [31:0] pc_f1;
reg        valid_f1;

assign bp_pc   = pc_f1;
assign ic_addr = pc_f1;

wire [31:0] seq_pc = bp_taken ? bp_target : (pc_f1 + 32'd4);

// IF. 记为 F2
reg [31:0] pc_f2;
reg        bp_taken_f2;
reg [31:0] bp_target_f2;
reg        valid_f2;

// 指令到了但本拍没交付出去则缓存
reg        inst_valid_f2;
reg [31:0] inst_f2;

// 指令本拍可用：刚返回 或 已缓冲
wire data_here  = valid_f2 & ic_data_ok;
wire f2_ready_go = data_here | inst_valid_f2;
wire f2_allowin = ~valid_f2 | (f2_ready_go & ID_allow_in);

// F1 -> F2
assign ic_req  = valid_f1 & f2_allowin & ~flush;
wire   f1_fire = ic_req & ic_addr_ok;

// F2 -> ID
assign IF_to_ID_valid = valid_f2 & f2_ready_go & ~flush;
wire   f2_fire        = IF_to_ID_valid & ID_allow_in;
wire [31:0] inst_to_id = inst_valid_f2 ? inst_f2 : ic_rdata;

assign IF_to_ID_BUS = '{pc: pc_f2, inst: inst_to_id,
                        bp_taken: bp_taken_f2, bp_target: bp_target_f2};

always @(posedge clk) begin
    if (reset) valid_f1 <= 1'b0;
    else       valid_f1 <= 1'b1;
end

always @(posedge clk) begin
    if (reset)        pc_f1 <= RESET_PC;
    else if (flush)   pc_f1 <= redirect_target;
    else if (f1_fire) pc_f1 <= seq_pc;
end

always @(posedge clk) begin
    if (reset | flush) valid_f2 <= 1'b0;
    else if (f1_fire)  valid_f2 <= 1'b1;
    else if (f2_fire)  valid_f2 <= 1'b0;
end

always @(posedge clk) begin
    if (f1_fire) begin
        pc_f2        <= pc_f1;
        bp_taken_f2  <= bp_taken;
        bp_target_f2 <= bp_target;
    end
end

always @(posedge clk) begin
    if (reset | flush)             inst_valid_f2 <= 1'b0;
    else if (f1_fire)              inst_valid_f2 <= 1'b0;
    else if (data_here & ~f2_fire) inst_valid_f2 <= 1'b1;
    else if (f2_fire)              inst_valid_f2 <= 1'b0;
end

always @(posedge clk) begin
    if (reset) inst_f2 <= 32'b0;
    else if (data_here & ~f2_fire) inst_f2 <= ic_rdata;
end

endmodule
