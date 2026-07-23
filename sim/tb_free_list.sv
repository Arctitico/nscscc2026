`timescale 1ns/1ps
import cpu_pkg::*;

module tb_free_list;
    logic clk = 1'b0;
    logic reset = 1'b1;
    always #5 clk = ~clk;

    logic alloc_fire, alloc_req0, alloc_req1;
    logic alloc_ready, alloc_valid0, alloc_valid1;
    preg_t alloc_preg0, alloc_preg1;
    logic free_valid0, free_valid1;
    preg_t free_preg0, free_preg1;
    logic restore_valid;
    logic [PREG_COUNT-1:0] restore_bitmap;
    logic [PREG_COUNT-1:0] free_bitmap;
    logic [PREG_COUNT-1:0] checkpoint;

    preg_free_list dut (.*);

    task automatic tick;
        @(posedge clk);
        #1;
    endtask

    task automatic check_condition(input logic condition, input string message);
        if (!condition) begin
            $display("FREE LIST TEST FAILED: %s", message);
            $fatal(1);
        end
    endtask

    initial begin
        alloc_fire = 1'b0;
        alloc_req0 = 1'b0;
        alloc_req1 = 1'b0;
        free_valid0 = 1'b0;
        free_valid1 = 1'b0;
        free_preg0 = '0;
        free_preg1 = '0;
        restore_valid = 1'b0;
        restore_bitmap = '0;

        tick();
        reset = 1'b0;
        #1;
        check_condition($countones(free_bitmap) == 32, "reset 后应有 32 个空闲物理寄存器");

        alloc_req0 = 1'b1;
        alloc_req1 = 1'b1;
        #1;
        check_condition(alloc_ready && alloc_preg0 == preg_t'(32) &&
                        alloc_preg1 == preg_t'(33), "首次双分配应得到 p32/p33");
        alloc_fire = 1'b1;
        tick();
        check_condition($countones(free_bitmap) == 30, "双分配后空闲数应减 2");

        checkpoint = free_bitmap;
        alloc_req1 = 1'b0;
        #1;
        check_condition(alloc_preg0 == preg_t'(34), "下一次分配应得到 p34");
        tick();

        alloc_fire = 1'b0;
        alloc_req0 = 1'b0;
        free_valid0 = 1'b1;
        free_preg0 = preg_t'(32);
        free_valid1 = 1'b1;
        free_preg1 = preg_t'(33);
        tick();
        check_condition(free_bitmap[32] && free_bitmap[33], "提交释放应归还 p32/p33");

        free_valid0 = 1'b0;
        free_valid1 = 1'b0;
        alloc_req0 = 1'b1;
        alloc_req1 = 1'b1;
        #1;
        check_condition(alloc_preg0 == preg_t'(32) && alloc_preg1 == preg_t'(33),
                        "归还的低编号 tag 应按优先级重新分配");

        alloc_req0 = 1'b0;
        alloc_req1 = 1'b0;
        restore_bitmap = checkpoint;
        restore_valid = 1'b1;
        tick();
        restore_valid = 1'b0;
        check_condition(free_bitmap == checkpoint, "checkpoint restore 应原样恢复 free bitmap");

        restore_bitmap = '0;
        restore_bitmap[63] = 1'b1;
        restore_valid = 1'b1;
        tick();
        restore_valid = 1'b0;
        alloc_req0 = 1'b1;
        alloc_req1 = 1'b1;
        #1;
        check_condition(!alloc_ready && alloc_valid0 && !alloc_valid1 &&
                        alloc_preg0 == preg_t'(63),
                        "只剩一个 tag 时不得接受双分配");

        $display("FREE LIST TEST PASSED");
        $finish;
    end
endmodule
