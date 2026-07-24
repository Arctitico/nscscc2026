// ============================================================================
// sram_ctrl —— 多周期异步 SRAM 控制器（单请求口，支持读突发）
//
// 把「请求保持到 ok」握手翻译成板上异步 SRAM 时序：
//   - 单字（len=0）：发起后驱动 addr/ce/oe(读) 或 addr/data/be/ce/we(写) 保持
//     LATENCY+1 拍，末拍组合给出 ok（读时同拍 rdata 有效），与原版完全一致。
//   - 读突发（len>0，仅取指重填用）：CE/OE 全程拉低，逐字推进 addr，每字访问
//     LATENCY+1 拍后给出一个 beat（ok），到第 len 字时 beat_last=1 再回 IDLE。
//     每字仍有 LATENCY+1 拍访问时间，时序裕量与单字相同；省掉了字间回 IDLE 的
//     重启/总线翻转开销，是真正的连读突发。
//   - 写恒为单字（len=0；本工程只取指走突发、访存单字）。
//   - 物理数据线是 inout，三态在板级顶层处理。本模块额外输出 ram_wdrive：
//     写周期结束、WE# 上升后仍保持地址/字节使能/写数据和数据总线驱动一整拍，
//     避免板上 SRAM 在 WE# 边沿附近采到已经释放的总线。
//   - tag 原样随每个 beat 带回（tag_out），供上层把结果路由回「取指/访存」发起方。
// ============================================================================
module sram_ctrl #(
    parameter integer LATENCY = 2
) (
    input  wire        clk,
    input  wire        reset,

    // SRAM 物理侧（三态在顶层）
    output reg  [19:0] ram_addr,
    output reg  [ 3:0] ram_be_n,
    output reg         ram_ce_n,
    output reg         ram_oe_n,
    output reg         ram_we_n,
    output wire        ram_wdrive,
    output reg  [31:0] ram_wdat,
    input  wire [31:0] ram_rdat,

    // 请求侧（单口；req 保持到首个 ok / 突发到 beat_last）
    input  wire        req,
    input  wire [ 3:0] wstrb,    // 0=读，非 0=写（字节使能）
    input  wire [19:0] addr,     // 字地址（首字）
    input  wire [31:0] wdata,
    input  wire [ 2:0] len,      // 突发字数-1（0=单字；写恒 0）
    input  wire        tag_in,   // 发起方标记（0=取指 1=访存），原样带回
    output wire        ok,        // 每 beat 一拍（读时同拍 rdata 有效）
    output wire [31:0] rdata,
    output wire        beat_last, // 突发最后一个 beat（单字时与 ok 同拍）
    output reg         tag_out,
    output wire        busy
);

localparam        S_IDLE = 1'b0, S_ACC = 1'b1;
reg        state;
reg  [7:0] cnt;
reg  [2:0] widx;       // 当前 beat 序号
reg  [2:0] len_r;      // 本次突发字数-1
reg        write_hold; // WE# 上升后的整拍数据保持

assign busy      = (state != S_IDLE);
assign ok        = (state == S_ACC) && (cnt == 8'd0);   // 每字访问末拍
assign beat_last = ok && (widx == len_r);
assign rdata     = ram_rdat;                            // 读：末拍数据已稳定，组合直通
assign ram_wdrive = ~ram_we_n | write_hold;

always @(posedge clk) begin
    if (reset) begin
        state    <= S_IDLE;
        ram_ce_n <= 1'b1; ram_oe_n <= 1'b1; ram_we_n <= 1'b1;
        ram_be_n <= 4'h0; ram_addr <= 20'b0; ram_wdat <= 32'b0;
        tag_out  <= 1'b0; cnt <= 8'b0; widx <= 3'b0; len_r <= 3'b0;
        write_hold <= 1'b0;
    end else begin
        // 上一拍 WE# 为低时，本拍继续驱动旧写数据。ram_addr/ram_be_n/ram_wdat
        // 只有接收新请求时才更新，因此整个保持窗口内不会改变。
        write_hold <= ~ram_we_n;
        case (state)
        S_IDLE: begin
            ram_ce_n <= 1'b1; ram_oe_n <= 1'b1; ram_we_n <= 1'b1;
            if (req) begin
                tag_out  <= tag_in;
                ram_addr <= addr;
                ram_wdat <= wdata;
                ram_be_n <= (|wstrb) ? ~wstrb : 4'h0;   // 读：全字节使能
                ram_ce_n <= 1'b0;
                ram_oe_n <= (|wstrb) ? 1'b1 : 1'b0;     // 读拉低 oe
                ram_we_n <= (|wstrb) ? 1'b0 : 1'b1;     // 写拉低 we
                cnt      <= LATENCY[7:0];
                widx     <= 3'b0;
                len_r    <= len;
                state    <= S_ACC;
            end
        end
        S_ACC: begin
            if (cnt != 8'd0) begin
                cnt <= cnt - 8'd1;
            end else if (widx == len_r) begin           // 最后一字（含单字）
                ram_ce_n <= 1'b1; ram_oe_n <= 1'b1;
                ram_we_n <= 1'b1;                        // 写：上升沿锁存
                state    <= S_IDLE;                      // 下一拍可接新请求
            end else begin                               // 突发：推进到下一字（CE/OE 不抬）
                widx     <= widx + 3'd1;
                ram_addr <= ram_addr + 20'd1;
                cnt      <= LATENCY[7:0];
            end
        end
        default: state <= S_IDLE;
        endcase
    end
end

endmodule
