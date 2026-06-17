// ============================================================================
// Branch Prediction Unit
//
// 走向乱序双发射时需扩展：一拍双 PC 查询、推测式 RAS、与重命名/冲刷快照对接
// ============================================================================
module bpu #(
    parameter int NSET   = 64,            // BTB 项数（2 的幂）
    parameter int IDXLSB = 2,             // 索引起始位（字对齐，pc[1:0]恒0）
    parameter int IDXW   = $clog2(NSET)   // 索引位宽
) (
    input  wire        clk,
    input  wire        reset,

    // prediction query
    input  wire [31:0] pred_pc,
    output wire        pred_taken,        
    output wire [31:0] pred_target,       

    // update
    input  wire        upd_en,            
    input  wire [31:0] upd_pc,           
    input  wire        upd_taken,         
    input  wire        upd_is_cond,       // 是否是条件分支(beq/bne)
    input  wire [31:0] upd_target         
);

localparam int TAGLSB = IDXLSB + IDXW;    // 标签起始位
localparam int TAGW   = 32 - TAGLSB;      // 标签位宽

reg [NSET-1:0]   btb_valid;               
reg [TAGW-1:0]   btb_tag   [0:NSET-1];
reg [31:0]       btb_target[0:NSET-1];
reg [1:0]        btb_cnt   [0:NSET-1];    // 饱和计数器
reg              btb_cond  [0:NSET-1];    // 该项是否为条件分支

wire [IDXW-1:0] p_idx = pred_pc[IDXLSB +: IDXW];
wire [TAGW-1:0] p_tag = pred_pc[TAGLSB +: TAGW];
wire            p_hit = btb_valid[p_idx] & (btb_tag[p_idx] == p_tag);

assign pred_taken  = p_hit & (btb_cond[p_idx] ? btb_cnt[p_idx][1] : 1'b1);
assign pred_target = btb_target[p_idx];

wire [IDXW-1:0] u_idx = upd_pc[IDXLSB +: IDXW];
wire [TAGW-1:0] u_tag = upd_pc[TAGLSB +: TAGW];
wire            u_hit = btb_valid[u_idx] & (btb_tag[u_idx] == u_tag);

// 饱和计数器增减
wire [1:0] cnt_cur  = btb_cnt[u_idx];
wire [1:0] cnt_next = upd_taken ? (cnt_cur == 2'b11 ? 2'b11 : cnt_cur + 2'b01)
                                : (cnt_cur == 2'b00 ? 2'b00 : cnt_cur - 2'b01);

integer i;
always @(posedge clk or posedge reset) begin
    if (reset) begin
        btb_valid <= '0;
    end
    else if (upd_en) begin
        if (!u_hit) begin
            // 未命中: 仅当实际跳转才更新
            if (upd_taken) begin
                btb_valid [u_idx] <= 1'b1;
                btb_tag   [u_idx] <= u_tag;
                btb_target[u_idx] <= upd_target;
                btb_cond  [u_idx] <= upd_is_cond;
                btb_cnt   [u_idx] <= 2'b10;
            end
        end
        else begin
            // 命中: 更新计数器；跳转时刷新目标
            btb_cnt [u_idx] <= cnt_next;
            btb_cond[u_idx] <= upd_is_cond;
            if (upd_taken) btb_target[u_idx] <= upd_target;
        end
    end
end

endmodule
