// ============================================================================
// Execute 1：双 ALU、双 AGU、双槽分支解析与 D-cache 地址请求。
//
// 本阶段只在 EX2 能接收时发出访存请求，并把“地址已接受”和 bundle 入 EX2
// 合并为同一次握手，保证每条访存只请求一次。IS 保证一个 bundle 最多一个
// 分支、一个乘法和一个访存，并禁止 slot0 分支携带年轻访存。
// ============================================================================
import cpu_pkg::*;

module EX1 (
    input  wire               clk,
    input  wire               reset,
    input  wire               flush,

    input  wire               RF_to_EX1_valid,
    input  wire               EX2_allow_in,
    output wire               EX1_allow_in,
    output wire               EX1_to_EX2_valid,

    input  rf_to_ex_bus_t     RF_to_EX1_BUS,
    output ex1_to_ex2_bus_t   EX1_to_EX2_BUS,

    output wire               redirect,
    output wire   [31:0]      redirect_target,

    output wire               bp_upd_en,
    output wire   [31:0]      bp_upd_pc,
    output wire               bp_upd_taken,
    output wire               bp_upd_is_cond,
    output wire   [31:0]      bp_upd_target,

    output fwd_bus_t          ex1_fwd0,
    output fwd_bus_t          ex1_fwd1,

    output wire               data_sram_en,
    output wire   [ 3:0]      data_sram_we,
    output wire   [ 2:0]      data_sram_size,
    output wire   [31:0]      data_sram_addr,
    output wire   [31:0]      data_sram_wdata,
    input  wire               data_addr_ok,

    output wire               perf_data_wait,
    output wire               perf_branch_mispred
);

reg             ex1_valid;
rf_to_ex_bus_t  ex1_r;

rf_ex_slot_t s0;
rf_ex_slot_t s1;
assign s0 = ex1_r.s0;
assign s1 = ex1_r.s1;

wire ex1_v0 = ex1_valid;
wire ex1_v1 = ex1_valid & ex1_r.v1;

wire [31:0] alu_result0;
wire [31:0] alu_result1;
alu u_alu0(.alu_src1(s0.alu_src1), .alu_src2(s0.alu_src2),
           .alu_op(s0.alu_op), .alu_result(alu_result0));
alu u_alu1(.alu_src1(s1.alu_src1), .alu_src2(s1.alu_src2),
           .alu_op(s1.alu_op), .alu_result(alu_result1));

function automatic [31:0] cpucfg(input [31:0] index);
    case (index)
        32'h0000_0010: cpucfg = 32'h0000_0000;
        default:       cpucfg = 32'h0000_0000;
    endcase
endfunction

wire [31:0] base_result0 = s0.is_cpucfg ? cpucfg(s0.alu_src1) : alu_result0;
wire [31:0] base_result1 = s1.is_cpucfg ? cpucfg(s1.alu_src1) : alu_result1;

// ---------------- 双槽分支解析；IS 保证至多一个分支 ----------------
wire        eq0         = (s0.alu_src1 == s0.rkd_value);
wire        uncond0     = s0.is_branch & ~s0.inst_beq & ~s0.inst_bne;
wire        cond_taken0 = (s0.inst_beq & eq0) | (s0.inst_bne & ~eq0);
wire        br_taken0   = ex1_v0 & (uncond0 | cond_taken0);
wire [31:0] br_target0  = s0.inst_jirl ? (s0.alu_src1 + s0.imm)
                                         : (s0.pc + s0.imm);
wire mispred0 = ex1_v0 & s0.is_branch &
                ((s0.bp_taken ^ br_taken0) |
                 (br_taken0 & s0.bp_taken & (br_target0 != s0.bp_target)));

wire        eq1         = (s1.alu_src1 == s1.rkd_value);
wire        uncond1     = s1.is_branch & ~s1.inst_beq & ~s1.inst_bne;
wire        cond_taken1 = (s1.inst_beq & eq1) | (s1.inst_bne & ~eq1);
wire        br_taken1   = ex1_v1 & (uncond1 | cond_taken1);
wire [31:0] br_target1  = s1.inst_jirl ? (s1.alu_src1 + s1.imm)
                                         : (s1.pc + s1.imm);
wire mispred1 = ex1_v1 & s1.is_branch &
                ((s1.bp_taken ^ br_taken1) |
                 (br_taken1 & s1.bp_taken & (br_target1 != s1.bp_target)));

wire branch_sel1 = ex1_v1 & s1.is_branch;
wire branch_mispred = mispred0 | mispred1;
assign redirect_target = branch_sel1
                       ? (br_taken1 ? br_target1 : (s1.pc + 32'd4))
                       : (br_taken0 ? br_target0 : (s0.pc + 32'd4));

// ---------------- 单数据口；两套 AGU ----------------
wire is_mem0 = ex1_v0 & (s0.is_ld | s0.is_st);
wire is_mem1 = ex1_v1 & (s1.is_ld | s1.is_st);
wire has_mem = is_mem0 | is_mem1;
wire mem_sel1 = is_mem1;

(* keep = "true" *) wire [31:0] mem_addr0 = s0.alu_src1 + s0.alu_src2;
(* keep = "true" *) wire [31:0] mem_addr1 = s1.alu_src1 + s1.alu_src2;
wire [31:0] mem_addr = mem_sel1 ? mem_addr1 : mem_addr0;
wire        st_sel   = mem_sel1 ? s1.is_st : s0.is_st;
wire        stb_sel  = mem_sel1 ? s1.is_st_b : s0.is_st_b;
wire [ 3:0] ldw_sel  = mem_sel1 ? s1.ld_width : s0.ld_width;
wire [31:0] rkd_sel  = mem_sel1 ? s1.rkd_value : s0.rkd_value;

wire [ 3:0] st_wstrb = stb_sel ? (4'b0001 << mem_addr[1:0]) : 4'b1111;
wire [31:0] st_wdata = stb_sel ? {4{rkd_sel[7:0]}} : rkd_sel;

// 请求只在 EX2 能原子接收本 bundle 时出现；addr_ok 的同一边沿将 bundle
// 锁存进 EX2，所以下一拍不会重复请求。
assign data_sram_en    = ex1_valid & has_mem & EX2_allow_in;
assign data_sram_we    = data_sram_en & st_sel ? st_wstrb : 4'b0;
assign data_sram_size  = (stb_sel | (ldw_sel == 4'b0001)) ? 3'b000 : 3'b010;
assign data_sram_addr  = mem_addr;
assign data_sram_wdata = st_wdata;

wire ex1_ready_go = ~has_mem | data_addr_ok;
assign EX1_to_EX2_valid = ex1_valid & ex1_ready_go;
wire ex1_fire = EX1_to_EX2_valid & EX2_allow_in;
assign EX1_allow_in = ~ex1_valid | ex1_fire;

assign redirect = branch_mispred & ex1_fire;
assign perf_data_wait = ex1_valid & has_mem & EX2_allow_in & ~data_addr_ok;
assign perf_branch_mispred = redirect;

assign bp_upd_en      = ex1_fire &
                        ((ex1_v0 & s0.is_branch) | (ex1_v1 & s1.is_branch));
assign bp_upd_pc      = branch_sel1 ? s1.pc : s0.pc;
assign bp_upd_taken   = branch_sel1 ? br_taken1 : br_taken0;
assign bp_upd_is_cond = branch_sel1 ? (s1.inst_beq | s1.inst_bne)
                                    : (s0.inst_beq | s0.inst_bne);
assign bp_upd_target  = branch_sel1 ? br_target1 : br_target0;

always @(posedge clk) begin
    if (reset | flush)        ex1_valid <= 1'b0;
    else if (EX1_allow_in)    ex1_valid <= RF_to_EX1_valid;
end

always @(posedge clk) begin
    if (RF_to_EX1_valid & EX1_allow_in) ex1_r <= RF_to_EX1_BUS;
end

assign EX1_to_EX2_BUS = '{
    s0: '{pc: s0.pc, inst: s0.inst, base_result: base_result0,
          mul_src1: s0.mul_src1, mul_src2: s0.mul_src2, is_mul: s0.is_mul,
          is_mem: is_mem0, addr_lo: mem_addr0[1:0],
          ld_width: s0.ld_width, ld_ext_signed: s0.ld_ext_signed,
          rf_wdata_sel: s0.rf_wdata_sel, rf_we: s0.rf_we, rf_waddr: s0.rf_waddr},
    s1: '{pc: s1.pc, inst: s1.inst, base_result: base_result1,
          mul_src1: s1.mul_src1, mul_src2: s1.mul_src2, is_mul: s1.is_mul,
          is_mem: is_mem1, addr_lo: mem_addr1[1:0],
          ld_width: s1.ld_width, ld_ext_signed: s1.ld_ext_signed,
          rf_wdata_sel: s1.rf_wdata_sel, rf_we: s1.rf_we, rf_waddr: s1.rf_waddr},
    v1: ex1_v1 & ~mispred0
};

wire [31:0] fwd_data0 = (s0.rf_wdata_sel == 2'b10) ? (s0.pc + 32'd4)
                                                     : base_result0;
wire [31:0] fwd_data1 = (s1.rf_wdata_sel == 2'b10) ? (s1.pc + 32'd4)
                                                     : base_result1;

assign ex1_fwd0 = '{valid: ex1_v0, rf_we: s0.rf_we,
                    is_ld: s0.is_ld | s0.is_mul,
                    rf_waddr: s0.rf_waddr, rf_wdata: fwd_data0};
// slot0 分支配对的年轻结果等到 EX2 才可见，避免分支比较进入 RF 旁路。
assign ex1_fwd1 = '{valid: ex1_v1, rf_we: s1.rf_we,
                    is_ld: s1.is_ld | s1.is_mul | s0.is_branch,
                    rf_waddr: s1.rf_waddr, rf_wdata: fwd_data1};

endmodule
