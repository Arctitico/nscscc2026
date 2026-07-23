// ============================================================================
// 双分配物理寄存器 free-list 原语
//
// p0-p31 初始保留给 ARF 同名映射，p32-p63 可分配。分配只观察拍初 bitmap，
// 同拍归还的 tag 从下一拍起可再次分配，避免提交释放与 rename 形成组合环。
// restore 用于后续分支 checkpoint/异常恢复；当前 RR 同名映射阶段尚不消费它。
// ============================================================================
import cpu_pkg::*;

module preg_free_list (
    input  wire                  clk,
    input  wire                  reset,

    input  wire                  alloc_fire,
    input  wire                  alloc_req0,
    input  wire                  alloc_req1,
    output wire                  alloc_ready,
    output wire                  alloc_valid0,
    output preg_t                alloc_preg0,
    output wire                  alloc_valid1,
    output preg_t                alloc_preg1,

    input  wire                  free_valid0,
    input  preg_t                free_preg0,
    input  wire                  free_valid1,
    input  preg_t                free_preg1,

    input  wire                  restore_valid,
    input  wire [PREG_COUNT-1:0] restore_bitmap,
    output wire [PREG_COUNT-1:0] free_bitmap
);

localparam logic [PREG_COUNT-1:0] INITIAL_FREE =
    {PREG_COUNT{1'b1}} << ARCH_REG_COUNT;

logic [PREG_COUNT-1:0] free_bitmap_r;
logic [PREG_COUNT-1:0] free_bitmap_n;
logic [PREG_COUNT-1:0] avail_after0;

function automatic preg_t first_free(input logic [PREG_COUNT-1:0] bitmap);
    preg_t selected;
    logic  found;
    selected = '0;
    found = 1'b0;
    for (int unsigned i = 0; i < PREG_COUNT; i++) begin
        if (bitmap[i] && !found) begin
            selected = preg_t'(i);
            found = 1'b1;
        end
    end
    return selected;
endfunction

assign alloc_valid0 = alloc_req0 & (|free_bitmap_r);
assign alloc_preg0  = first_free(free_bitmap_r);

always_comb begin
    avail_after0 = free_bitmap_r;
    if (alloc_valid0) avail_after0[alloc_preg0] = 1'b0;
end

assign alloc_valid1 = alloc_req1 & (|avail_after0);
assign alloc_preg1  = first_free(avail_after0);
assign alloc_ready  = (~alloc_req0 | alloc_valid0) &
                      (~alloc_req1 | alloc_valid1);

always_comb begin
    free_bitmap_n = free_bitmap_r;

    // 恒不允许回收 p0-p31；它们在初始/同名映射阶段是架构状态锚点。
    if (free_valid0 && (free_preg0 >= preg_t'(ARCH_REG_COUNT)))
        free_bitmap_n[free_preg0] = 1'b1;
    if (free_valid1 && (free_preg1 >= preg_t'(ARCH_REG_COUNT)))
        free_bitmap_n[free_preg1] = 1'b1;

    if (alloc_fire && alloc_ready) begin
        if (alloc_req0) free_bitmap_n[alloc_preg0] = 1'b0;
        if (alloc_req1) free_bitmap_n[alloc_preg1] = 1'b0;
    end
end

always_ff @(posedge clk) begin
    if (reset)
        free_bitmap_r <= INITIAL_FREE;
    else if (restore_valid)
        free_bitmap_r <= restore_bitmap & INITIAL_FREE;
    else
        free_bitmap_r <= free_bitmap_n;
end

assign free_bitmap = free_bitmap_r;

endmodule
