// ============================================================================
// sram_ctrl —— 多周期异步 SRAM 控制器（单请求口，支持读突发）
//
// 把「请求保持到 ok」握手翻译成板上异步 SRAM 时序：
//   - 单字（len=0）：发起后驱动 addr/ce/oe(读) 或 addr/data/be/ce/we(写) 保持
//     READ_CYCLES / WRITE_CYCLES 拍，末拍组合给出 ok（读时同拍 rdata 有效）。
//   - 读突发（len>0，I/D cache line 重填用）：CE/OE 全程拉低，逐字推进
//     addr，每字访问
//     READ_CYCLES 拍后给出一个 beat（ok），到第 len 字时 beat_last=1 再回 IDLE。
//     每字仍有 READ_CYCLES 拍访问时间，时序裕量与单字相同；省掉了字间回 IDLE 的
//     重启/总线翻转开销。四字 line burst 可从 critical word 开始，地址低两位
//     在同一 16 B line 内回绕。
//   - 写恒为单字（len=0）。
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
    (* IOB = "TRUE" *) output reg  [19:0] ram_addr,
    (* IOB = "TRUE" *) output reg  [ 3:0] ram_be_n,
    (* IOB = "TRUE" *) output reg         ram_ce_n,
    (* IOB = "TRUE" *) output reg         ram_oe_n,
    (* IOB = "TRUE" *) output reg         ram_we_n,
    // Drive only the enabled byte lanes.  Besides avoiding unnecessary bus
    // activity, this gives each IOB T-register cone only eight loads.
    (* IOB = "TRUE" *) output reg  [ 3:0] ram_wdrive,
    (* IOB = "TRUE" *) output reg  [31:0] ram_wdat,
    input  wire [31:0] ram_rdat,

    // 请求侧（单口；req 保持到首个 ok / 突发到 beat_last）
    input  wire        req,
    input  wire [ 3:0] wstrb,    // 0=读，非 0=写（字节使能）
    input  wire [19:0] addr,     // 字地址（首字）
    input  wire [31:0] wdata,
    input  wire [ 2:0] len,      // 突发字数-1（0=单字；写恒 0）
    input  wire        tag_in,   // 发起方标记（0=取指 1=访存），原样带回
    output wire        ok,        // 每 beat 一拍（读时同拍 rdata 有效）
    output reg         rd_ok,     // 已按访问类型 one-hot 登记的完成脉冲
    output reg         wr_ok,
    output reg         rd_ok_inst, // 已在寄存边界按发起方拆分，避免返回后长组合路由
    output reg         rd_ok_data,
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
reg        write_r;    // 当前访问类型，供物理引脚寄存器在结束拍判断
reg        ok_q;

// 保持窗口的最后一拍可以提前向上游给 ready；真正接收发生在该拍末沿，
// 此时地址/数据已经完整保持 WRITE_HOLD_CYCLES 拍，不引入额外空泡。
assign busy      = (state != S_IDLE) || (write_hold_count > 16'd1);
wire accept_req = (state == S_IDLE) && req &&
                  (write_hold_count <= 16'd1);

// 原组合 ok=(state==S_ACC && cnt==0) 会从控制器计数器一直穿过
// mem_bridge、cache、EX2 completion 和整条 ready 链。这里在前一拍根据
// 当前状态预测“下一拍是否为访问末拍”，登记出的 ok_q 与原 ok 在同一
// 协议周期有效，因此切断返回控制路径而不增加 SRAM 访问拍数。
wire accept_one_cycle = accept_req &&
                        ((|wstrb) ? (WRITE_COUNT_INIT == 16'd0)
                                  : (READ_COUNT_INIT  == 16'd0));
wire advance_to_last_cycle = (state == S_ACC) && (cnt == 16'd1);
wire next_burst_one_cycle = (state == S_ACC) && (cnt == 16'd0) &&
                            (widx != len_r) &&
                            (READ_COUNT_INIT == 16'd0);
wire complete_next = accept_one_cycle | advance_to_last_cycle |
                     next_burst_one_cycle;
wire complete_next_write =
    (accept_one_cycle & (|wstrb)) |
    (advance_to_last_cycle & write_r);
// 一拍 SRAM 在接收沿同时更新 tag_out，分类时须直接使用本次 tag_in；
// 其余完成拍使用已登记且在整次突发期间稳定的 tag_out。
wire complete_next_tag = accept_one_cycle ? tag_in : tag_out;

assign ok        = ok_q;
assign beat_last = ok && (widx == len_r);
assign rdata     = ram_rdat;                            // 读：末拍数据已稳定，组合直通

always @(posedge clk) begin
    if (reset) begin
        ok_q <= 1'b0;
        rd_ok <= 1'b0;
        wr_ok <= 1'b0;
        rd_ok_inst <= 1'b0;
        rd_ok_data <= 1'b0;
    end else begin
        ok_q <= complete_next;
        // 与 ok_q 在同一沿预测并登记访问类型，避免完成返回后再由
        // mem_bridge 的 is_write 状态组合解码。协议周期与 ok 完全相同。
        rd_ok <= complete_next & ~complete_next_write;
        wr_ok <= complete_next_write;
        rd_ok_inst <= complete_next & ~complete_next_write &
                      ~complete_next_tag;
        rd_ok_data <= complete_next & ~complete_next_write &
                      complete_next_tag;
    end
end

// 协议状态只使用同步复位。不要让这些寄存器带异步复位：它们会经过
// mem_bridge 影响 CPU cache RAM 的地址/控制输入，异步控制会触发
// RAMB18 REQP-1840，并显著恶化布局布线与时序。
always @(posedge clk) begin
    if (reset) begin
        state    <= S_IDLE;
        tag_out  <= 1'b0; cnt <= 16'b0; widx <= 3'b0; len_r <= 3'b0;
        write_hold_count <= 16'b0;
        write_r <= 1'b0;
    end else begin
        if (write_hold_count != 16'd0)
            write_hold_count <= write_hold_count - 16'd1;
        case (state)
        S_IDLE: begin
            // write_hold_count==1 表示当前正处在保持窗口的最后一拍；本沿接收
            // 新请求只会在完整保持结束之后更新地址/数据，因而可无缝衔接。
            if (accept_req) begin
                tag_out  <= tag_in;
                cnt      <= (|wstrb) ? WRITE_COUNT_INIT : READ_COUNT_INIT;
                widx     <= 3'b0;
                len_r    <= len;
                write_r  <= |wstrb;
                state    <= S_ACC;
            end
        end
        S_ACC: begin
            if (cnt != 16'd0) begin
                cnt <= cnt - 16'd1;
            end else if (widx == len_r) begin           // 最后一字（含单字）
                if (write_r)
                    write_hold_count <= WRITE_HOLD_INIT;
                state    <= S_IDLE;                      // 下一拍可接新请求
            end else begin                               // 突发：推进到下一字（CE/OE 不抬）
                widx     <= widx + 3'd1;
                cnt      <= READ_COUNT_INIT;
            end
        end
        default: state <= S_IDLE;
        endcase
    end
end

// 只有直接连到板级 SRAM 的引脚寄存器使用异步复位。这样即使 PLL 尚未
// 输出 cpu_clk，CE#/OE#/WE# 和 FPGA 数据线驱动也会立即回到安全状态；
// 复位释放仍由顶层 cpu_reset 的同步释放链保证。
always @(posedge clk or posedge reset) begin
    if (reset) begin
        ram_ce_n   <= 1'b1;
        ram_oe_n   <= 1'b1;
        ram_we_n   <= 1'b1;
        ram_be_n   <= 4'hf;
        ram_addr   <= 20'b0;
        ram_wdat   <= 32'b0;
        ram_wdrive <= 4'b0000;
    end else begin
        case (state)
        S_IDLE: begin
            ram_ce_n <= 1'b1;
            ram_oe_n <= 1'b1;
            ram_we_n <= 1'b1;
            if (accept_req) begin
                ram_addr   <= addr;
                ram_wdat   <= wdata;
                ram_be_n   <= (|wstrb) ? ~wstrb : 4'h0;
                ram_ce_n   <= 1'b0;
                ram_oe_n   <= (|wstrb) ? 1'b1 : 1'b0;
                ram_we_n   <= (|wstrb) ? 1'b0 : 1'b1;
                ram_wdrive <= wstrb;
            end else if (write_hold_count <= 16'd1) begin
                ram_wdrive <= 4'b0000;
            end
        end
        S_ACC: begin
            if ((cnt == 16'd0) && (widx == len_r)) begin
                ram_ce_n <= 1'b1;
                ram_oe_n <= 1'b1;
                ram_we_n <= 1'b1;                       // 写：上升沿锁存
                if (!write_r)
                    ram_wdrive <= 4'b0000;
            end else if (cnt == 16'd0) begin
                // 四字 cache-line 读可从 critical word 开始，只递增低两位，
                // 例如 word3 后回到同一行的 word0，不向相邻行进位。
                ram_addr <= (!write_r && (len_r == 3'd3))
                          ? {ram_addr[19:2], ram_addr[1:0] + 2'd1}
                          : ram_addr + 20'd1;
            end
        end
        default: begin
            ram_ce_n   <= 1'b1;
            ram_oe_n   <= 1'b1;
            ram_we_n   <= 1'b1;
            ram_wdrive <= 4'b0000;
        end
        endcase
    end
end

endmodule
