// ============================================================================
// Execute 2 / Completion：接收已寄存乘积并等待 D-cache 响应，生成写回数据。
//
// EX1 的专用乘法操作数寄存器与本级乘积寄存器组成 II=1 的两级乘法流水。
// 一个 bundle 可以同时含一个 mul 和一个 mem；若访存较慢，本级仍分别锁存
// 先到的完成状态及载荷，只有 s0/s1（有效时）都完成才向 CM 前进。
// ============================================================================
import cpu_pkg::*;

module EX2 (
    input  wire               clk,
    input  wire               reset,

    input  wire               EX1_to_EX2_valid,
    input  wire               CM_allow_in,
    output wire               EX2_allow_in,
    output wire               EX2_to_CM_valid,

    input  ex1_to_ex2_bus_t   EX1_to_EX2_BUS,
    output ex_to_cm_bus_t     EX2_to_CM_BUS,

    output fwd_bus_t          ex2_fwd0,
    output fwd_bus_t          ex2_fwd1,
    output wire               ex2_load_valid,
    output wire   [ 4:0]      ex2_load_waddr,
    output wire   [31:0]      ex2_load_wdata,

    input  wire   [31:0]      data_sram_rdata,
    input  wire               data_ok,

    output wire               perf_data_wait,
    output wire               perf_mul_wait
);

reg                  ex2_valid;
ex1_to_ex2_bus_t     ex2_r;

ex1_ex2_slot_t s0;
ex1_ex2_slot_t s1;
assign s0 = ex2_r.s0;
assign s1 = ex2_r.s1;

wire ex2_v0 = ex2_valid;
wire ex2_v1 = ex2_valid & ex2_r.v1;
// 保留随机测试使用的层级调试名。
wire ex_v1_eff = ex2_v1;

// s1.is_mul 已在 EX1 只用 pre-kill valid 掩码。允许随后因 slot0 分支
// mispredict 或 selfmod 命中而被精确 kill 的 slot1 MUL 投机启动，避免
// AGU/I-cache tag 比较经 BUS.v1 一直进入 DSP CE。
wire incoming_mul1 = EX1_to_EX2_BUS.s1.is_mul;
wire incoming_mul  = EX1_to_EX2_BUS.s0.is_mul | incoming_mul1;
// IS 保证一个 bundle 至多一条 MUL。操作数选择只需看已寄存的 slot0
// 类型；不要使用含 mispred0 精确 kill 的 v1，否则会形成
// PC/分支比较 -> slot1 选择 -> DSP 数据口的长组合路径。被 kill 时
// incoming_mul=0，乘法器不会采样此处的 don't-care 操作数。
wire incoming_mul_sel1 = ~EX1_to_EX2_BUS.s0.is_mul;
wire ex2_mul1      = ex2_r.v1 & s1.is_mul;
wire ex2_has_mul   = s0.is_mul | ex2_mul1;
wire ex2_has_mem   = s0.is_mem | (ex2_r.v1 & s1.is_mem);

reg         s0_done_q;
reg         s1_done_q;
reg [31:0]  mul_result_q;
reg [31:0]  mem_result_q;

wire        mul_in_valid;
wire        mul_in_ready;
wire        mul_out_valid;
wire        mul_out_ready;
wire [31:0] mul_low;
wire [31:0] mul_high_unused;

wire s0_done_now = (~s0.is_mul & ~s0.is_mem) |
                   (s0.is_mul & mul_out_valid) |
                   (s0.is_mem & data_ok);
wire s1_done_now = (~s1.is_mul & ~s1.is_mem) |
                   (s1.is_mul & mul_out_valid) |
                   (s1.is_mem & data_ok);
wire s0_ready_go = s0_done_q | s0_done_now;
wire s1_ready_go = ~ex2_r.v1 | s1_done_q | s1_done_now;
wire ex2_ready_go = s0_ready_go & s1_ready_go;
assign EX2_to_CM_valid = ex2_valid & ex2_ready_go;
wire ex2_fire = EX2_to_CM_valid & CM_allow_in;
wire ex2_slot_allow = ~ex2_valid | ex2_fire;
// 乘法 token 与 EX2 bundle 一一对应：EX2 空闲时乘法器必为空；旧 bundle
// fire 时，旧乘积要么当拍被消费，要么早已保存并消费。因此 EX2 能接收时
// mul_in_ready 恒成立，无需把 incoming branch-kill/mul 选择串进 allow_in。
assign EX2_allow_in = ex2_slot_allow;

assign mul_in_valid = EX1_to_EX2_valid & EX2_allow_in & incoming_mul;
// 结果一出现就接收；若另一长延迟单元尚未完成，则在本级锁存保存。
// 对动态 kill 的 slot1 MUL，EX2 bundle 仍有效而 ex2_has_mul=0，token
// 在这里直接消费并丢弃，不能留在乘法器里阻塞后续真实 MUL。
assign mul_out_ready = ex2_valid;

mul u_mul (
    .clk(clk), .reset(reset),
    .in_valid(mul_in_valid), .in_ready(mul_in_ready),
    .a_in(incoming_mul_sel1 ? EX1_to_EX2_BUS.s1.mul_src1
                            : EX1_to_EX2_BUS.s0.mul_src1),
    .b_in(incoming_mul_sel1 ? EX1_to_EX2_BUS.s1.mul_src2
                            : EX1_to_EX2_BUS.s0.mul_src2),
    .is_signed(1'b1),
    .out_valid(mul_out_valid), .out_ready(mul_out_ready),
    .c_low(mul_low), .c_high(mul_high_unused)
);

always @(posedge clk) begin
    if (reset)              ex2_valid <= 1'b0;
    else if (EX2_allow_in)  ex2_valid <= EX1_to_EX2_valid;
end

always @(posedge clk) begin
    // valid=0 时 payload 无关；只以本级 allow 作 CE，缩短大总线控制路径。
    if (EX2_allow_in) ex2_r <= EX1_to_EX2_BUS;
end

always @(posedge clk) begin
    if (reset) begin
        s0_done_q <= 1'b0;
        s1_done_q <= 1'b0;
    end
    else if (EX2_allow_in) begin
        s0_done_q <= 1'b0;
        s1_done_q <= 1'b0;
    end
    else begin
        if (ex2_valid & s0_done_now)
            s0_done_q <= 1'b1;
        if (ex2_valid & ex2_r.v1 & s1_done_now)
            s1_done_q <= 1'b1;
        if (ex2_valid & ex2_has_mul & mul_out_valid)
            mul_result_q <= mul_low;
        if (ex2_valid & ex2_has_mem & data_ok)
            mem_result_q <= data_sram_rdata;
    end
end

function automatic [31:0] load_data(input ex1_ex2_slot_t w,
                                    input [31:0] mem_rdata);
    logic [7:0]  byte_sel;
    logic [15:0] half_sel;
    byte_sel = (w.addr_lo == 2'b00) ? mem_rdata[ 7: 0] :
               (w.addr_lo == 2'b01) ? mem_rdata[15: 8] :
               (w.addr_lo == 2'b10) ? mem_rdata[23:16] : mem_rdata[31:24];
    half_sel = w.addr_lo[1] ? mem_rdata[31:16] : mem_rdata[15:0];
    case (w.ld_width)
        4'b1111: load_data = mem_rdata;
        4'b0011: load_data = w.ld_ext_signed ? {{16{half_sel[15]}}, half_sel}
                                              : {16'b0, half_sel};
        4'b0001: load_data = w.ld_ext_signed ? {{24{byte_sel[7]}}, byte_sel}
                                              : {24'b0, byte_sel};
        default: load_data = mem_rdata;
    endcase
endfunction

function automatic [31:0] write_data(input ex1_ex2_slot_t w,
                                     input [31:0] mem_rdata,
                                     input [31:0] mul_result);
    case (w.rf_wdata_sel)
        2'b01:   write_data = load_data(w, mem_rdata);
        2'b10:   write_data = w.pc + 32'd4;
        default: write_data = w.is_mul ? mul_result : w.base_result;
    endcase
endfunction

wire mul_saved = (s0.is_mul & s0_done_q) |
                 (ex2_r.v1 & s1.is_mul & s1_done_q);
wire mem_saved = (s0.is_mem & s0_done_q) |
                 (ex2_r.v1 & s1.is_mem & s1_done_q);
wire mul_complete = ~ex2_has_mul | mul_saved | mul_out_valid;
wire mem_complete = ~ex2_has_mem | mem_saved | data_ok;
wire [31:0] mem_result = mem_saved ? mem_result_q : data_sram_rdata;
wire [31:0] mul_result = mul_saved ? mul_result_q : mul_low;
wire [31:0] rf_wdata0 = write_data(s0, mem_result, mul_result);
wire [31:0] rf_wdata1 = write_data(s1, mem_result, mul_result);

assign EX2_to_CM_BUS = '{
    s0: '{pc: s0.pc, inst: s0.inst, rf_wdata: rf_wdata0,
          rf_we: s0.rf_we, rf_waddr: s0.rf_waddr},
    s1: '{pc: s1.pc, inst: s1.inst, rf_wdata: rf_wdata1,
          rf_we: s1.rf_we, rf_waddr: s1.rf_waddr},
    v1: ex2_v1
};

assign ex2_fwd0 = '{valid: ex2_v0,
                    rf_we: s0.rf_we,
                    result_ready: ~((s0.is_mem & ~mem_complete) |
                                    (s0.is_mul & ~mul_complete)),
                    rf_waddr: s0.rf_waddr, rf_wdata: rf_wdata0};
assign ex2_fwd1 = '{valid: ex2_v1,
                    rf_we: s1.rf_we,
                    result_ready: ~((s1.is_mem & ~mem_complete) |
                                    (s1.is_mul & ~mul_complete)),
                    rf_waddr: s1.rf_waddr, rf_wdata: rf_wdata1};

wire ex2_load0 = ex2_v0 & s0.is_mem & s0.rf_we;
wire ex2_load1 = ex2_v1 & s1.is_mem & s1.rf_we;

assign ex2_load_valid = mem_complete & (ex2_load0 | ex2_load1);
assign ex2_load_waddr = ex2_load1 ? s1.rf_waddr : s0.rf_waddr;
assign ex2_load_wdata = ex2_load1 ? rf_wdata1 : rf_wdata0;

assign perf_data_wait = ex2_valid & ex2_has_mem & ~mem_complete;
assign perf_mul_wait  = ex2_valid & ex2_has_mul & ~mul_complete;

endmodule
