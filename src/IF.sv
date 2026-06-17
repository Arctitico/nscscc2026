// ============================================================================
// Instruction Fetch
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

    output wire             inst_sram_en,
    output wire   [31:0]    inst_sram_addr,
    input  wire   [31:0]    inst_sram_rdata,
    input  wire             inst_ok
);

localparam [31:0] RESET_PC = 32'h8000_0000;

reg [31:0] pc;
reg        if_valid;
reg        redir_pend;       // 取指在途时发生过重定向 → 当前在途取指结果作废
reg [31:0] redir_pc;         // 重定向目标（最新者优先）

assign inst_sram_en   = if_valid;
assign inst_sram_addr = pc;
assign bp_pc          = pc;

// 仅当取指完成、当前取指未被作废、且本拍无新重定向时，才向 ID 交付
assign IF_to_ID_valid = if_valid & inst_ok & ~redir_pend & ~redirect;
assign IF_to_ID_BUS   = '{pc: pc, inst: inst_sram_rdata, bp_taken: bp_taken, bp_target: bp_target};

// 预测的顺序下一 PC
wire [31:0] seq_pc = bp_taken ? bp_target : (pc + 32'd4);

always @(posedge clk or posedge reset) begin
    if (reset) if_valid <= 1'b0;
    else       if_valid <= 1'b1;
end

// 锁存最新的重定向目标
always @(posedge clk or posedge reset) begin
    if (reset)         redir_pc <= 32'b0;
    else if (redirect) redir_pc <= redirect_target;
end

always @(posedge clk or posedge reset) begin
    if (reset)                                   redir_pend <= 1'b0;
    else if (inst_ok & (redirect | redir_pend))  redir_pend <= 1'b0;
    else if (~inst_ok & redirect)                redir_pend <= 1'b1;
end

always @(posedge clk or posedge reset) begin
    if (reset)                                    pc <= RESET_PC;
    else if (inst_ok & (redirect | redir_pend))   pc <= redirect ? redirect_target : redir_pc;
    else if (if_valid & inst_ok & ID_allow_in)    pc <= seq_pc;
end

endmodule
