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
    input  wire [31:0] pred_pc0,
    output wire        pred_taken0,
    output wire [31:0] pred_target0,
    input  wire [31:0] pred_pc1,
    output wire        pred_taken1,
    output wire [31:0] pred_target1,

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

wire [IDXW-1:0] p0_idx = pred_pc0[IDXLSB +: IDXW];
wire [TAGW-1:0] p0_tag = pred_pc0[TAGLSB +: TAGW];
wire            p0_hit = btb_valid[p0_idx] & (btb_tag[p0_idx] == p0_tag);
assign pred_taken0  = p0_hit & (btb_cond[p0_idx] ? btb_cnt[p0_idx][1] : 1'b1);
assign pred_target0 = btb_target[p0_idx];

wire [IDXW-1:0] p1_idx = pred_pc1[IDXLSB +: IDXW];
wire [TAGW-1:0] p1_tag = pred_pc1[TAGLSB +: TAGW];
wire            p1_hit = btb_valid[p1_idx] & (btb_tag[p1_idx] == p1_tag);
assign pred_taken1  = p1_hit & (btb_cond[p1_idx] ? btb_cnt[p1_idx][1] : 1'b1);
assign pred_target1 = btb_target[p1_idx];

// 分支解析包含目标地址加法、误预测判断和双槽选择。若直接用这组组合信号写
// distributed RAM，100 MHz 下会形成 EX -> BTB 写使能/数据的长路径。先把训练
// 请求登记一拍；预测正确性不依赖训练在解析当拍完成，连续训练仍可每拍接收一条。
reg             upd_valid_q;
reg [31:0]      upd_pc_q;
reg             upd_taken_q;
reg             upd_is_cond_q;
reg [31:0]      upd_target_q;

wire [IDXW-1:0] u_idx_q = upd_pc_q[IDXLSB +: IDXW];
wire [TAGW-1:0] u_tag_q = upd_pc_q[TAGLSB +: TAGW];
wire            u_hit_q = btb_valid[u_idx_q] & (btb_tag[u_idx_q] == u_tag_q);

// 饱和计数器增减
wire [1:0] cnt_cur  = btb_cnt[u_idx_q];
wire [1:0] cnt_next = upd_taken_q ? (cnt_cur == 2'b11 ? 2'b11 : cnt_cur + 2'b01)
                                  : (cnt_cur == 2'b00 ? 2'b00 : cnt_cur - 2'b01);

always @(posedge clk) begin
    if (reset) begin
        upd_valid_q <= 1'b0;
    end
    else begin
        upd_valid_q <= upd_en;
        if (upd_en) begin
            upd_pc_q       <= upd_pc;
            upd_taken_q    <= upd_taken;
            upd_is_cond_q  <= upd_is_cond;
            upd_target_q   <= upd_target;
        end
    end
end

always @(posedge clk) begin
    if (reset) begin
        btb_valid <= '0;
    end
    else if (upd_valid_q) begin
        if (!u_hit_q) begin
            // 未命中: 仅当实际跳转才更新
            if (upd_taken_q) begin
                btb_valid [u_idx_q] <= 1'b1;
                btb_tag   [u_idx_q] <= u_tag_q;
                btb_target[u_idx_q] <= upd_target_q;
                btb_cond  [u_idx_q] <= upd_is_cond_q;
                btb_cnt   [u_idx_q] <= 2'b10;
            end
        end
        else begin
            // 命中: 更新计数器；跳转时刷新目标
            btb_cnt [u_idx_q] <= cnt_next;
            btb_cond[u_idx_q] <= upd_is_cond_q;
            if (upd_taken_q) btb_target[u_idx_q] <= upd_target_q;
        end
    end
end

endmodule
