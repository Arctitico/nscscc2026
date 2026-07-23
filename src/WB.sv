// ============================================================================
// Tagged LSU response / Write Back
//
// D-cache 在接受请求时保存 ex_wb_slot_t，并在 hit/refill/uncached/store
// 完成时原样返回。这里登记响应并完成 load 对齐/扩展。请求的选择性
// 冲刷由保存请求的 MSHR 按 ROB 年龄执行，WB 不能仅凭全局 epoch 丢弃
// 响应，否则会误杀已发射但尚未完成的更老 store。
// 整数 fast completion 与本通道独立，因而连续 load hit 不再占住
// EX/WB bundle，也不与同拍双 ALU 争用完成端口。
// ============================================================================
import cpu_pkg::*;

module WB (
    input  wire             clk,
    input  wire             reset,
    input  wire             flush,
    input  epoch_t          current_epoch,
    input  rob_idx_t        recover_idx,
    input  rob_idx_t        rob_head_idx,

    input  wire             data_resp_valid,
    input  ex_wb_slot_t     data_resp_meta,
    input  wire   [31:0]    data_resp_rdata,

    output wire             mem_complete_valid,
    output wb_cm_slot_t     mem_complete_slot,
    output fwd_bus_t        mem_fwd,
    output wire             perf_data_wait
);

reg          wb_valid;
ex_wb_slot_t wb_meta;
reg [31:0]   wb_rdata;

function automatic logic younger_than_recover(input rob_idx_t idx);
    logic [ROB_BITS:0] idx_age;
    logic [ROB_BITS:0] recover_age;
    idx_age = {1'b0, idx - rob_head_idx};
    recover_age = {1'b0, recover_idx - rob_head_idx};
    younger_than_recover = (idx_age > recover_age);
endfunction

always_ff @(posedge clk) begin
    if (reset) begin
        wb_valid <= 1'b0;
    end else begin
        wb_valid <= data_resp_valid;
        if (data_resp_valid) begin
            wb_meta  <= data_resp_meta;
            wb_rdata <= data_resp_rdata;
        end
    end
end

function automatic [31:0] load_data(input ex_wb_slot_t w,
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

wire [31:0] result = (wb_meta.rf_wdata_sel == 2'b01)
                   ? load_data(wb_meta, wb_rdata)
                   : wb_meta.alu_result;
// flush/current_epoch 保留在接口上供后续断言与诊断；真正的选择性杀除
// 必须在持有全部未决项的 D-cache/MSHR 中进行。
assign mem_complete_valid =
    wb_valid & ~(flush && younger_than_recover(wb_meta.rob_idx));
assign mem_complete_slot = '{
    pc: wb_meta.pc,
    inst: wb_meta.inst,
    rf_wdata: result,
    rf_we: wb_meta.rf_we,
    rf_waddr: wb_meta.rf_waddr,
    pdst: wb_meta.pdst,
    old_pdst: wb_meta.old_pdst,
    rob_idx: wb_meta.rob_idx
};

assign mem_fwd = '{
    valid: mem_complete_valid,
    rf_we: wb_meta.rf_we,
    is_ld: 1'b0,
    pdst: wb_meta.pdst,
    rf_wdata: result
};

// 等待现在发生在 D-cache/MSHR 中；保留统计端口兼容顶层。
assign perf_data_wait = 1'b0;

endmodule
