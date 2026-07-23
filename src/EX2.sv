// ============================================================================
// Execute 2 / Completion：等待乘法器和 D-cache 响应，生成最终写回数据。
//
// 阶段一仍保证 bundle 中不会同时出现 mul 与 mem，因此 ready_go 保持单一
// 长延迟源选择；后续扩大发射矩阵时在这里加入逐槽 sticky completion。
// ============================================================================
import cpu_pkg::*;

module EX2 (
    input  wire               clk,
    input  wire               reset,

    input  wire               EX1_to_EX2_valid,
    input  wire               WB_allow_in,
    output wire               EX2_allow_in,
    output wire               EX2_to_WB_valid,

    input  ex1_to_ex2_bus_t   EX1_to_EX2_BUS,
    output ex_to_wb_bus_t     EX2_to_WB_BUS,

    output fwd_bus_t          ex2_fwd0,
    output fwd_bus_t          ex2_fwd1,

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

wire incoming_mul1 = EX1_to_EX2_BUS.v1 & EX1_to_EX2_BUS.s1.is_mul;
wire incoming_mul  = EX1_to_EX2_BUS.s0.is_mul | incoming_mul1;
wire ex2_mul1      = ex2_r.v1 & s1.is_mul;
wire ex2_has_mul   = s0.is_mul | ex2_mul1;
wire ex2_has_mem   = s0.is_mem | (ex2_r.v1 & s1.is_mem);

wire        mul_in_valid;
wire        mul_in_ready;
wire        mul_out_valid;
wire        mul_out_ready;
wire [31:0] mul_low;
wire [31:0] mul_high_unused;

wire ex2_ready_go = ex2_has_mul ? mul_out_valid
                    : ex2_has_mem ? data_ok
                                  : 1'b1;
assign EX2_to_WB_valid = ex2_valid & ex2_ready_go;
wire ex2_fire = EX2_to_WB_valid & WB_allow_in;
wire ex2_slot_allow = ~ex2_valid | ex2_fire;
assign EX2_allow_in = ex2_slot_allow &
                      (~EX1_to_EX2_valid | ~incoming_mul | mul_in_ready);

assign mul_in_valid = EX1_to_EX2_valid & EX2_allow_in & incoming_mul;
assign mul_out_ready = ex2_fire & ex2_has_mul;

mul u_mul (
    .clk(clk), .reset(reset),
    .in_valid(mul_in_valid), .in_ready(mul_in_ready),
    .a_in(incoming_mul1 ? EX1_to_EX2_BUS.s1.mul_src1
                        : EX1_to_EX2_BUS.s0.mul_src1),
    .b_in(incoming_mul1 ? EX1_to_EX2_BUS.s1.mul_src2
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
    if (EX1_to_EX2_valid & EX2_allow_in) ex2_r <= EX1_to_EX2_BUS;
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

wire [31:0] rf_wdata0 = write_data(s0, data_sram_rdata, mul_low);
wire [31:0] rf_wdata1 = write_data(s1, data_sram_rdata, mul_low);

assign EX2_to_WB_BUS = '{
    s0: '{pc: s0.pc, inst: s0.inst, rf_wdata: rf_wdata0,
          rf_we: s0.rf_we, rf_waddr: s0.rf_waddr},
    s1: '{pc: s1.pc, inst: s1.inst, rf_wdata: rf_wdata1,
          rf_we: s1.rf_we, rf_waddr: s1.rf_waddr},
    v1: ex2_v1
};

assign ex2_fwd0 = '{valid: ex2_v0,
                    rf_we: s0.rf_we,
                    is_ld: s0.is_mem | (s0.is_mul & ~mul_out_valid),
                    rf_waddr: s0.rf_waddr, rf_wdata: rf_wdata0};
assign ex2_fwd1 = '{valid: ex2_v1,
                    rf_we: s1.rf_we,
                    is_ld: s1.is_mem | (s1.is_mul & ~mul_out_valid),
                    rf_waddr: s1.rf_waddr, rf_wdata: rf_wdata1};

assign perf_data_wait = ex2_valid & ex2_has_mem & ~data_ok;
assign perf_mul_wait  = ex2_valid & ex2_has_mul & ~mul_out_valid;

endmodule
