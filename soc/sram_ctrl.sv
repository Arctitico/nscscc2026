// ============================================================================
// sram_ctrl —— 通用多周期异步 SRAM 控制器（单请求口）
//
// 把「请求保持到 ok」的握手翻译成板上异步 SRAM 时序：发起后驱动 addr/ce/oe(读) 或
// addr/data/be/ce/we(写) 保持 LATENCY+1 拍，最后一拍组合给出 ok（读时同拍 rdata 有效）。
//   - 物理数据线是 inout，三态在板级顶层处理（本模块只出 ram_wdat + 控制位、入 ram_rdat），
//     故本模块可综合也可被 Verilator 直接仿真。
//   - 请求在 S_IDLE 一拍被锁存（addr/wdata/wstrb/tag 一并存入），其后忽略输入直至完成；
//     tag 原样随 ok 带回（tag_out），供上层把 ok 路由回「取指/访存」发起方。
//   - LATENCY = 进入访问态后额外保持的拍数（oe/we 拉低时长）；访问耗时 = LATENCY+1 拍，
//     再 1 拍总线翻转回 IDLE。50MHz 下异步 SRAM(~10ns) 取 1~2 即够，默认 2 留裕量。
//   - ok 是寄存器值(state/cnt)的组合译码，无毛刺；读数据在采样拍前已稳定（oe 已低数拍），
//     故末拍组合直通 rdata 时序宽松（只剩布线，不含 SRAM 访问时间）。
//   - 写：访问态全程 we 拉低、addr/data 稳定，回 IDLE 那拍 we 上升沿锁存写入。
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
    output reg  [31:0] ram_wdat,
    input  wire [31:0] ram_rdat,

    // 请求侧（单口；req 保持到 ok）
    input  wire        req,
    input  wire [ 3:0] wstrb,    // 0=读，非 0=写（字节使能）
    input  wire [19:0] addr,     // 字地址（cpu_addr[21:2]）
    input  wire [31:0] wdata,
    input  wire        tag_in,   // 发起方标记（0=取指 1=访存），原样带回
    output wire        ok,       // 完成（读时同拍 rdata 有效）
    output wire [31:0] rdata,
    output reg         tag_out,
    output wire        busy
);

localparam        S_IDLE = 1'b0, S_ACC = 1'b1;
reg               state;
reg  [7:0]        cnt;

assign busy  = (state != S_IDLE);
assign ok    = (state == S_ACC) && (cnt == 8'd0);   // 末拍完成
assign rdata = ram_rdat;                            // 读：末拍数据已稳定，组合直通

always @(posedge clk) begin
    if (reset) begin
        state    <= S_IDLE;
        ram_ce_n <= 1'b1; ram_oe_n <= 1'b1; ram_we_n <= 1'b1;
        ram_be_n <= 4'h0; ram_addr <= 20'b0; ram_wdat <= 32'b0;
        tag_out  <= 1'b0; cnt <= 8'b0;
    end else begin
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
                state    <= S_ACC;
            end
        end
        S_ACC: begin
            if (cnt == 8'd0) begin                       // 末拍（ok 此拍组合为 1）
                ram_ce_n <= 1'b1; ram_oe_n <= 1'b1;
                ram_we_n <= 1'b1;                        // 写：上升沿锁存
                state    <= S_IDLE;                      // 下一拍总线翻转/可接新请求
            end else begin
                cnt <= cnt - 8'd1;
            end
        end
        default: state <= S_IDLE;
        endcase
    end
end

endmodule
