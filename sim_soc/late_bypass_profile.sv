// Simulation-only accounting for the EX1 load-to-store-data late bypass.
module late_bypass_profile (
    input wire clk,
    input wire reset,
    input wire marker_start,
    input wire marker_end,
    input wire load_store_ready
);

reg counting;
reg [63:0] load_store_count;

always @(posedge clk) begin
    if (reset) begin
        counting         <= 1'b0;
        load_store_count <= 64'b0;
    end else if (marker_start) begin
        counting         <= 1'b1;
        load_store_count <= 64'b0;
    end else if (marker_end & counting) begin
        counting <= 1'b0;
        $display("[LATE BYPASS] load->store-data=%0d", load_store_count);
    end else if (counting) begin
        if (load_store_ready)
            load_store_count <= load_store_count + 64'd1;
    end
end

endmodule

bind tb_perf late_bypass_profile u_late_bypass_profile (
    .clk(clk),
    .reset(reset),
    .marker_start(marker_start),
    .marker_end(marker_end),
    .load_store_ready(
        u_cpu.u_EX1.ex1_valid & u_cpu.u_EX1.late_ready &
        (u_cpu.u_EX1.s0.late_store_data |
         (u_cpu.u_EX1.ex1_r.v1 & u_cpu.u_EX1.s1.late_store_data)))
);
