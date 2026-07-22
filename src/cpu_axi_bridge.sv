// ============================================================================
// CPU local memory ports -> 32-bit AXI master
//
// Interface organization follows the OpenLA500 axi_bridge idea, but the state
// machines are rewritten for this core's completion-based data_ok protocol:
//   - one outstanding read transaction (data load has priority over I-cache)
//   - four-beat INCR burst for a 16-byte I-cache line
//   - one outstanding single-beat write; AW and W handshake independently
//   - data read 的每个 R beat 都以 data_ok 返回给 D-cache；普通单拍 load
//     仍只有一个 beat，size=3'b100 表示 16B cache-line burst
//   - store 在 B response 时完成
// ============================================================================
module cpu_axi_bridge (
    input  wire        clk,
    input  wire        reset,

    output wire [ 3:0] arid,
    output wire [31:0] araddr,
    output wire [ 7:0] arlen,
    output wire [ 2:0] arsize,
    output wire [ 1:0] arburst,
    output wire [ 1:0] arlock,
    output wire [ 3:0] arcache,
    output wire [ 2:0] arprot,
    output wire        arvalid,
    input  wire        arready,

    input  wire [ 3:0] rid,
    input  wire [31:0] rdata,
    input  wire [ 1:0] rresp,
    input  wire        rlast,
    input  wire        rvalid,
    output wire        rready,

    output wire [ 3:0] awid,
    output wire [31:0] awaddr,
    output wire [ 7:0] awlen,
    output wire [ 2:0] awsize,
    output wire [ 1:0] awburst,
    output wire [ 1:0] awlock,
    output wire [ 3:0] awcache,
    output wire [ 2:0] awprot,
    output wire        awvalid,
    input  wire        awready,

    output wire [ 3:0] wid,
    output wire [31:0] wdata,
    output wire [ 3:0] wstrb,
    output wire        wlast,
    output wire        wvalid,
    input  wire        wready,

    input  wire [ 3:0] bid,
    input  wire [ 1:0] bresp,
    input  wire        bvalid,
    output wire        bready,

    input  wire        inst_rd_req,
    input  wire [31:0] inst_rd_addr,
    output wire        inst_rd_rdy,
    output wire        inst_ret_valid,
    output wire [31:0] inst_ret_data,
    output wire        inst_ret_last,

    input  wire        data_rd_req,
    input  wire [ 2:0] data_rd_size,
    input  wire [31:0] data_rd_addr,
    output wire [31:0] data_rd_data,
    output wire        data_rd_ok,

    input  wire        data_wr_req,
    input  wire [ 2:0] data_wr_size,
    input  wire [31:0] data_wr_addr,
    input  wire [ 3:0] data_wr_strb,
    input  wire [31:0] data_wr_data,
    output wire        data_wr_ok
);

// ------------------------------ read channel ------------------------------
localparam [1:0] RD_IDLE = 2'd0;
localparam [1:0] RD_ADDR = 2'd1;
localparam [1:0] RD_DATA = 2'd2;

reg [1:0]  rd_state;
reg        rd_is_data;
reg [31:0] rd_addr;
reg [ 7:0] rd_len;
reg [ 2:0] rd_size;

wire data_rd_line = (data_rd_size == 3'b100);

always @(posedge clk) begin
    if (reset) begin
        rd_state <= RD_IDLE;
    end else begin
        case (rd_state)
            RD_IDLE: begin
                // A stalled load is older than a pending I-cache miss.
                if (data_rd_req) begin
                    rd_is_data <= 1'b1;
                    rd_addr    <= data_rd_addr;
                    rd_len     <= data_rd_line ? 8'd3 : 8'd0;
                    rd_size    <= data_rd_line ? 3'b010 : data_rd_size;
                    rd_state   <= RD_ADDR;
                end else if (inst_rd_req) begin
                    rd_is_data <= 1'b0;
                    rd_addr    <= inst_rd_addr;
                    rd_len     <= 8'd3;
                    rd_size    <= 3'b010;
                    rd_state   <= RD_ADDR;
                end
            end
            RD_ADDR: begin
                if (arready)
                    rd_state <= RD_DATA;
            end
            RD_DATA: begin
                if (rvalid && rready && rlast)
                    rd_state <= RD_IDLE;
            end
            default: rd_state <= RD_IDLE;
        endcase
    end
end

assign arid    = {3'b000, rd_is_data};
assign araddr  = rd_addr;
assign arlen   = rd_len;
assign arsize  = rd_size;
assign arburst = 2'b01;
assign arlock  = 2'b00;
assign arcache = 4'b0000;
assign arprot  = 3'b000;
assign arvalid = (rd_state == RD_ADDR);
assign rready  = (rd_state == RD_DATA);

assign inst_rd_rdy    = (rd_state == RD_ADDR) && !rd_is_data && arready;
assign inst_ret_valid = (rd_state == RD_DATA) && !rd_is_data && rvalid;
assign inst_ret_data  = rdata;
assign inst_ret_last  = inst_ret_valid && rlast;

wire data_rd_beat = (rd_state == RD_DATA) && rd_is_data && rvalid && rready;
assign data_rd_data = rdata;
assign data_rd_ok   = data_rd_beat;

// ------------------------------ write channel -----------------------------
localparam [1:0] WR_IDLE = 2'd0;
localparam [1:0] WR_SEND = 2'd1;
localparam [1:0] WR_RESP = 2'd2;

reg [1:0]  wr_state;
reg        aw_done;
reg        w_done;
reg [31:0] wr_addr;
reg [ 2:0] wr_size;
reg [31:0] wr_data;
reg [ 3:0] wr_strb;

wire aw_fire = awvalid && awready;
wire w_fire  = wvalid  && wready;

always @(posedge clk) begin
    if (reset) begin
        wr_state <= WR_IDLE;
    end else begin
        case (wr_state)
            WR_IDLE: begin
                if (data_wr_req) begin
                    wr_addr  <= data_wr_addr;
                    wr_size  <= data_wr_size;
                    wr_data  <= data_wr_data;
                    wr_strb  <= data_wr_strb;
                    aw_done  <= 1'b0;
                    w_done   <= 1'b0;
                    wr_state <= WR_SEND;
                end
            end
            WR_SEND: begin
                if (aw_fire) aw_done <= 1'b1;
                if (w_fire)  w_done  <= 1'b1;
                if ((aw_done || aw_fire) && (w_done || w_fire))
                    wr_state <= WR_RESP;
            end
            WR_RESP: begin
                if (bvalid && bready)
                    wr_state <= WR_IDLE;
            end
            default: wr_state <= WR_IDLE;
        endcase
    end
end

assign awid    = 4'b0001;
assign awaddr  = wr_addr;
assign awlen   = 8'd0;
assign awsize  = wr_size;
assign awburst = 2'b01;
assign awlock  = 2'b00;
assign awcache = 4'b0000;
assign awprot  = 3'b000;
assign awvalid = (wr_state == WR_SEND) && !aw_done;

assign wid    = 4'b0001;
assign wdata  = wr_data;
assign wstrb  = wr_strb;
assign wlast  = 1'b1;
assign wvalid = (wr_state == WR_SEND) && !w_done;
assign bready = (wr_state == WR_RESP);

wire data_wr_done = (wr_state == WR_RESP) && bvalid && bready;
assign data_wr_ok = data_wr_done;

// Response IDs/codes are intentionally not used by this single-outstanding
// baseline. The official SoC returns OKAY and preserves the issued ID.
wire unused_responses = ^{rid, rresp, bid, bresp};

endmodule
