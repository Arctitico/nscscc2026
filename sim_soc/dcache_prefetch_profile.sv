// D-cache next-line prefetch trace model for tb_perf.
//
// This monitor does not change DUT behavior. It records cacheable load locality,
// refill timing, SRAM-bank occupancy, and a two-bit-confidence next-line model.
module dcache_prefetch_profile (
    input wire        clk,
    input wire        reset,
    input wire        marker_start,
    input wire        marker_end,
    input wire        load_accept,
    input wire [31:0] load_addr,
    input wire        hit,
    input wire        miss,
    input wire [31:0] miss_addr,
    input wire        refill_fire,
    input wire        refill_last,
    input wire        refill_req,
    input wire        data_wr_req,
    input wire        base_busy,
    input wire        base_tag,
    input wire        base_write,
    input wire        base_req,
    input wire        ext_busy,
    input wire        ext_tag,
    input wire        ext_write,
    input wire        ext_req
);

reg counting;
reg [63:0] cycles;

reg [63:0] load_count;
reg [63:0] hit_count;
reg [63:0] miss_count;
reg [63:0] load_seq_word;
reg [63:0] load_same_line;
reg [63:0] load_other;
reg [63:0] miss_next_line;
reg [63:0] miss_same_line;
reg [63:0] miss_other_line;
reg [63:0] miss_after_seq_word;
reg [63:0] miss_after_word3;

reg [63:0] postfill_next;
reg [63:0] postfill_lt8;
reg [63:0] postfill_lt16;
reg [63:0] postfill_lt32;
reg [63:0] postfill_ge32;
reg [63:0] refill_beats;
reg [63:0] refill_req_cycles;
reg [63:0] refill_write_overlap;

reg [63:0] base_idle;
reg [63:0] base_inst;
reg [63:0] base_data_read;
reg [63:0] base_data_write;
reg [63:0] ext_idle;
reg [63:0] ext_inst;
reg [63:0] ext_data_read;
reg [63:0] ext_data_write;

reg        last_load_valid;
reg [31:0] last_load_addr;
reg        miss_predecessor_valid;
reg [31:0] miss_predecessor_addr;
reg        prev_miss_valid;
reg [31:0] prev_miss_line;
reg        last_fill_valid;
reg [31:0] last_fill_line;
reg [63:0] last_fill_cycle;

reg [1:0]  confidence;
reg        candidate_active;
reg        candidate_started;
reg        candidate_complete;
reg [31:0] candidate_line;
reg [63:0] candidate_start_cycle;
reg [63:0] predicted;
reg [63:0] predicted_correct;
reg [63:0] predicted_wrong;
reg [63:0] predicted_timely;
reg [63:0] predicted_late;
reg [63:0] predicted_no_start;
reg [63:0] predicted_blocked_req;

wire [31:0] miss_line = {miss_addr[31:4], 4'b0};
wire [63:0] fill_gap = cycles - last_fill_cycle;
wire candidate_base = candidate_line[31:22] == 10'h070;
wire candidate_bank_available = candidate_base ? (~base_busy & ~base_req)
                                                : (~ext_busy & ~ext_req);
wire candidate_bank_request = candidate_base ? base_req : ext_req;
wire candidate_finishes_now = candidate_started &&
                              ((cycles - candidate_start_cycle) >= 64'd8);

always @(posedge clk) begin
    if (reset) begin
        counting <= 1'b0;
    end else if (marker_start) begin
        counting <= 1'b1;
        cycles <= 64'b0;
        load_count <= 64'b0;
        hit_count <= 64'b0;
        miss_count <= 64'b0;
        load_seq_word <= 64'b0;
        load_same_line <= 64'b0;
        load_other <= 64'b0;
        miss_next_line <= 64'b0;
        miss_same_line <= 64'b0;
        miss_other_line <= 64'b0;
        miss_after_seq_word <= 64'b0;
        miss_after_word3 <= 64'b0;
        postfill_next <= 64'b0;
        postfill_lt8 <= 64'b0;
        postfill_lt16 <= 64'b0;
        postfill_lt32 <= 64'b0;
        postfill_ge32 <= 64'b0;
        refill_beats <= 64'b0;
        refill_req_cycles <= 64'b0;
        refill_write_overlap <= 64'b0;
        base_idle <= 64'b0;
        base_inst <= 64'b0;
        base_data_read <= 64'b0;
        base_data_write <= 64'b0;
        ext_idle <= 64'b0;
        ext_inst <= 64'b0;
        ext_data_read <= 64'b0;
        ext_data_write <= 64'b0;
        last_load_valid <= 1'b0;
        prev_miss_valid <= 1'b0;
        last_fill_valid <= 1'b0;
        confidence <= 2'b00;
        candidate_active <= 1'b0;
        predicted <= 64'b0;
        predicted_correct <= 64'b0;
        predicted_wrong <= 64'b0;
        predicted_timely <= 64'b0;
        predicted_late <= 64'b0;
        predicted_no_start <= 64'b0;
        predicted_blocked_req <= 64'b0;
    end else if (marker_end && counting) begin
        counting <= 1'b0;
        $display("[DPREFETCH] loads=%0d hits=%0d misses=%0d",
                 load_count, hit_count, miss_count);
        $display("[DPREFETCH] load_delta seq_word=%0d same_line=%0d other=%0d",
                 load_seq_word, load_same_line, load_other);
        $display("[DPREFETCH] miss_delta next=%0d same=%0d other=%0d after_seq_word=%0d after_word3=%0d",
                 miss_next_line, miss_same_line, miss_other_line,
                 miss_after_seq_word, miss_after_word3);
        $display("[DPREFETCH] postfill_next=%0d gap <8=%0d <16=%0d <32=%0d >=32=%0d",
                 postfill_next, postfill_lt8, postfill_lt16,
                 postfill_lt32, postfill_ge32);
        $display("[DPREFETCH] refill beats=%0d req_cycles=%0d write_overlap=%0d",
                 refill_beats, refill_req_cycles, refill_write_overlap);
        $display("[DPREFETCH] base idle=%0d inst=%0d data_read=%0d data_write=%0d",
                 base_idle, base_inst, base_data_read, base_data_write);
        $display("[DPREFETCH] ext idle=%0d inst=%0d data_read=%0d data_write=%0d",
                 ext_idle, ext_inst, ext_data_read, ext_data_write);
        $display("[DPREDICT] predicted=%0d correct=%0d wrong=%0d timely=%0d late=%0d no_start=%0d blocked_req=%0d conf=%0d",
                 predicted, predicted_correct, predicted_wrong,
                 predicted_timely, predicted_late, predicted_no_start,
                 predicted_blocked_req, confidence);
    end else if (counting) begin
        cycles <= cycles + 64'd1;

        if (!base_busy)
            base_idle <= base_idle + 64'd1;
        else if (!base_tag)
            base_inst <= base_inst + 64'd1;
        else if (base_write)
            base_data_write <= base_data_write + 64'd1;
        else
            base_data_read <= base_data_read + 64'd1;

        if (!ext_busy)
            ext_idle <= ext_idle + 64'd1;
        else if (!ext_tag)
            ext_inst <= ext_inst + 64'd1;
        else if (ext_write)
            ext_data_write <= ext_data_write + 64'd1;
        else
            ext_data_read <= ext_data_read + 64'd1;

        if (load_accept) begin
            load_count <= load_count + 64'd1;
            if (last_load_valid) begin
                if (load_addr == last_load_addr + 32'd4)
                    load_seq_word <= load_seq_word + 64'd1;
                else if (load_addr[31:4] == last_load_addr[31:4])
                    load_same_line <= load_same_line + 64'd1;
                else
                    load_other <= load_other + 64'd1;
            end
            miss_predecessor_valid <= last_load_valid;
            miss_predecessor_addr <= last_load_addr;
            last_load_valid <= 1'b1;
            last_load_addr <= load_addr;
        end

        if (hit)
            hit_count <= hit_count + 64'd1;

        if (candidate_active && !candidate_started &&
            candidate_bank_available) begin
            candidate_started <= 1'b1;
            candidate_start_cycle <= cycles;
        end
        if (candidate_active && candidate_started && !candidate_complete) begin
            if (candidate_bank_request)
                predicted_blocked_req <= predicted_blocked_req + 64'd1;
            if (candidate_finishes_now)
                candidate_complete <= 1'b1;
        end

        if (miss) begin
            miss_count <= miss_count + 64'd1;

            if (candidate_active) begin
                predicted <= predicted + 64'd1;
                if (miss_line == candidate_line) begin
                    predicted_correct <= predicted_correct + 64'd1;
                    if (candidate_complete || candidate_finishes_now)
                        predicted_timely <= predicted_timely + 64'd1;
                    else if (candidate_started)
                        predicted_late <= predicted_late + 64'd1;
                    else
                        predicted_no_start <= predicted_no_start + 64'd1;
                end else begin
                    predicted_wrong <= predicted_wrong + 64'd1;
                end
                candidate_active <= 1'b0;
            end

            if (prev_miss_valid) begin
                if (miss_line == prev_miss_line + 32'd16) begin
                    miss_next_line <= miss_next_line + 64'd1;
                    if (confidence != 2'b11)
                        confidence <= confidence + 1'b1;
                end else begin
                    if (miss_line == prev_miss_line)
                        miss_same_line <= miss_same_line + 64'd1;
                    else
                        miss_other_line <= miss_other_line + 64'd1;
                    if (confidence != 2'b00)
                        confidence <= confidence - 1'b1;
                end
            end

            if (miss_predecessor_valid &&
                (miss_addr == miss_predecessor_addr + 32'd4)) begin
                miss_after_seq_word <= miss_after_seq_word + 64'd1;
                if (miss_predecessor_addr[3:2] == 2'b11)
                    miss_after_word3 <= miss_after_word3 + 64'd1;
            end

            if (last_fill_valid &&
                (miss_line == last_fill_line + 32'd16)) begin
                postfill_next <= postfill_next + 64'd1;
                if (fill_gap < 64'd8)
                    postfill_lt8 <= postfill_lt8 + 64'd1;
                else if (fill_gap < 64'd16)
                    postfill_lt16 <= postfill_lt16 + 64'd1;
                else if (fill_gap < 64'd32)
                    postfill_lt32 <= postfill_lt32 + 64'd1;
                else
                    postfill_ge32 <= postfill_ge32 + 64'd1;
            end

            prev_miss_valid <= 1'b1;
            prev_miss_line <= miss_line;
        end

        if (refill_fire)
            refill_beats <= refill_beats + 64'd1;
        if (refill_req) begin
            refill_req_cycles <= refill_req_cycles + 64'd1;
            if (data_wr_req)
                refill_write_overlap <= refill_write_overlap + 64'd1;
        end
        if (refill_last) begin
            last_fill_valid <= 1'b1;
            last_fill_line <= miss_line;
            last_fill_cycle <= cycles;
            candidate_active <= confidence[1];
            candidate_started <= 1'b0;
            candidate_complete <= 1'b0;
            candidate_line <= miss_line + 32'd16;
        end
    end
end

endmodule

bind tb_perf dcache_prefetch_profile u_dcache_prefetch_profile (
    .clk(clk),
    .reset(reset),
    .marker_start(marker_start),
    .marker_end(marker_end),
    .load_accept(u_cpu.u_dcache.cpu_accept &
                 ~(|u_cpu.u_dcache.cpu_we) &
                 (u_cpu.u_dcache.cpu_addr[31:23] == 9'h038)),
    .load_addr(u_cpu.u_dcache.cpu_addr),
    .hit(u_cpu.perf_dcache_hit_event),
    .miss(u_cpu.perf_dcache_miss_event),
    .miss_addr(u_cpu.u_dcache.req_addr),
    .refill_fire(u_cpu.u_dcache.refill_fire),
    .refill_last(u_cpu.u_dcache.refill_last),
    .refill_req(u_cpu.u_dcache.refill_req),
    .data_wr_req(data_wr_req),
    .base_busy(u_bridge.base_busy),
    .base_tag(u_bridge.u_base.tag_out),
    .base_write(u_bridge.u_base.write_r),
    .base_req(u_bridge.base_req),
    .ext_busy(u_bridge.ext_busy),
    .ext_tag(u_bridge.u_ext.tag_out),
    .ext_write(u_bridge.u_ext.write_r),
    .ext_req(u_bridge.ext_req)
);
