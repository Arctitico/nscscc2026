// ============================================================================
// sram_ctrl —— 多周期异步 SRAM 控制器（单请求口，支持读突发）
//
// 把「请求保持到 ok」握手翻译成板上异步 SRAM 时序：
//   - 单字（len=0）：发起后驱动 addr/ce/oe(读) 或 addr/data/be/ce/we(写) 保持
//     READ_CYCLES / WRITE_CYCLES 拍，末拍组合给出 ok（读时同拍 rdata 有效）。
//   - 读突发（len>0，仅取指重填用）：CE/OE 全程拉低，逐字推进 addr，每字访问
//     READ_CYCLES 拍后给出一个 beat（ok），到第 len 字时 beat_last=1 再回 IDLE。
//     每字仍有 READ_CYCLES 拍访问时间，时序裕量与单字相同；省掉了字间回 IDLE 的
//     重启/总线翻转开销，是真正的连读突发。
//   - 写恒为单字（len=0；本工程只取指走突发、访存单字）。
//   - 物理数据线是 inout，三态在板级顶层处理。本模块额外输出 ram_wdrive：
//     写周期结束、WE# 上升后仍保持地址/字节使能/写数据和数据总线驱动
//     WRITE_HOLD_CYCLES 拍，
//     避免板上 SRAM 在 WE# 边沿附近采到已经释放的总线。
//   - tag 原样随每个 beat 带回（tag_out），供上层把结果路由回「取指/访存」发起方。
// ============================================================================
module sram_ctrl #(
    parameter integer READ_CYCLES       = 3,
    parameter integer WRITE_CYCLES      = 3,
    parameter integer WRITE_HOLD_CYCLES = 1
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
localparam [15:0] READ_COUNT_INIT  = READ_CYCLES - 1;
localparam [15:0] WRITE_COUNT_INIT = WRITE_CYCLES - 1;
localparam [15:0] WRITE_HOLD_INIT  = WRITE_HOLD_CYCLES;
reg        state;
reg [15:0] cnt;
reg  [2:0] widx;       // 当前 beat 序号
reg  [2:0] len_r;      // 本次突发字数-1
reg [15:0] write_hold_count; // WE# 上升后的数据保持剩余拍数

// 保持窗口的最后一拍可以提前向上游给 ready；真正接收发生在该拍末沿，
// 此时地址/数据已经完整保持 WRITE_HOLD_CYCLES 拍，不引入额外空泡。
assign busy      = (state != S_IDLE) || (write_hold_count > 16'd1);
assign ok        = (state == S_ACC) && (cnt == 16'd0);  // 每字访问末拍
assign beat_last = ok && (widx == len_r);
assign rdata     = ram_rdat;                            // 读：末拍数据已稳定，组合直通
assign ram_wdrive = ~ram_we_n | (write_hold_count != 16'd0);

// reset 异步置位，使 PLL 尚未输出 cpu_clk 时物理 SRAM 控制信号也能立即
// 回到安全状态；释放仍由顶层 cpu_reset 的同步释放链保证。
always @(posedge clk or posedge reset) begin
    if (reset) begin
        state    <= S_IDLE;
        ram_ce_n <= 1'b1; ram_oe_n <= 1'b1; ram_we_n <= 1'b1;
        ram_be_n <= 4'hf; ram_addr <= 20'b0; ram_wdat <= 32'b0;
        tag_out  <= 1'b0; cnt <= 16'b0; widx <= 3'b0; len_r <= 3'b0;
        write_hold_count <= 16'b0;
    end else begin
        if (write_hold_count != 16'd0)
            write_hold_count <= write_hold_count - 16'd1;
        case (state)
        S_IDLE: begin
            ram_ce_n <= 1'b1; ram_oe_n <= 1'b1; ram_we_n <= 1'b1;
            // write_hold_count==1 表示当前正处在保持窗口的最后一拍；本沿接收
            // 新请求只会在完整保持结束之后更新地址/数据，因而可无缝衔接。
            if (req && (write_hold_count <= 16'd1)) begin
                tag_out  <= tag_in;
                ram_addr <= addr;
                ram_wdat <= wdata;
                ram_be_n <= (|wstrb) ? ~wstrb : 4'h0;   // 读：全字节使能
                ram_ce_n <= 1'b0;
                ram_oe_n <= (|wstrb) ? 1'b1 : 1'b0;     // 读拉低 oe
                ram_we_n <= (|wstrb) ? 1'b0 : 1'b1;     // 写拉低 we
                cnt      <= (|wstrb) ? WRITE_COUNT_INIT : READ_COUNT_INIT;
                widx     <= 3'b0;
                len_r    <= len;
                state    <= S_ACC;
            end
        end
        S_ACC: begin
            if (cnt != 16'd0) begin
                cnt <= cnt - 16'd1;
            end else if (widx == len_r) begin           // 最后一字（含单字）
                ram_ce_n <= 1'b1; ram_oe_n <= 1'b1;
                ram_we_n <= 1'b1;                        // 写：上升沿锁存
                if (!ram_we_n)
                    write_hold_count <= WRITE_HOLD_INIT;
                state    <= S_IDLE;                      // 下一拍可接新请求
            end else begin                               // 突发：推进到下一字（CE/OE 不抬）
                widx     <= widx + 3'd1;
                ram_addr <= ram_addr + 20'd1;
                cnt      <= READ_COUNT_INIT;
            end
        end
        default: state <= S_IDLE;
        endcase
    end
end

endmodule
