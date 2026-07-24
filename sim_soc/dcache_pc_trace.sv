// Optional per-load-PC demand-miss trace for tb_perf.
//
// Enable with, for example:
//   make perf-stream DTRACE=+dtrace=dtrace_stream.txt
//
// Each row contains:
//   miss_cycle fill_cycle load_pc cache_line_address
module dcache_pc_trace (
    input wire        clk,
    input wire        reset,
    input wire        marker_start,
    input wire        marker_end,
    input wire        load_accept,
    input wire [31:0] load_pc,
    input wire        miss,
    input wire [31:0] miss_addr,
    input wire        refill_last,
    input wire [63:0] perf_cycle
);

integer fd;
string trace_path;
reg trace_enable;
reg counting;
reg [31:0] accepted_pc;
reg [31:0] active_pc;
reg [31:0] active_line;
reg [63:0] active_miss_cycle;

initial begin
    fd = 0;
    trace_enable = $value$plusargs("dtrace=%s", trace_path);
    if (trace_enable) begin
        fd = $fopen(trace_path, "w");
        if (fd == 0)
            $fatal(1, "cannot open dcache trace %s", trace_path);
    end
end

always @(posedge clk) begin
    if (reset) begin
        counting <= 1'b0;
    end else begin
        if (marker_start)
            counting <= 1'b1;
        else if (marker_end) begin
            counting <= 1'b0;
            if (trace_enable)
                $fflush(fd);
        end

        if (load_accept)
            accepted_pc <= load_pc;

        if (trace_enable && counting && miss) begin
            active_pc <= accepted_pc;
            active_line <= {miss_addr[31:4], 4'b0};
            active_miss_cycle <= perf_cycle;
        end

        if (trace_enable && counting && refill_last)
            $fwrite(fd, "%0d %0d %08x %08x\n",
                    active_miss_cycle, perf_cycle, active_pc, active_line);
    end
end

final begin
    if (fd != 0)
        $fclose(fd);
end

endmodule

bind tb_perf dcache_pc_trace u_dcache_pc_trace (
    .clk(clk),
    .reset(reset),
    .marker_start(marker_start),
    .marker_end(marker_end),
    .load_accept(u_cpu.u_dcache.cpu_accept &
                 ~(|u_cpu.u_dcache.cpu_we) &
                 (u_cpu.u_dcache.cpu_addr[31:23] == 9'h038)),
    .load_pc(u_cpu.u_EX1.mem_sel1 ? u_cpu.u_EX1.s1.pc : u_cpu.u_EX1.s0.pc),
    .miss(u_cpu.perf_dcache_miss_event),
    .miss_addr(u_cpu.u_dcache.req_addr),
    .refill_last(u_cpu.u_dcache.refill_last),
    .perf_cycle(u_cpu.perf_cycle)
);
