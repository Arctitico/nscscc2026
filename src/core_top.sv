// ============================================================================
// Official NSCSCC solo SoC CPU wrapper
// ============================================================================
module core_top #(
    parameter TLBNUM = 32
) (
    input  wire        aclk,
    input  wire        aresetn,
    input  wire [ 7:0] intrpt,

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

    input  wire        break_point,
    input  wire        infor_flag,
    input  wire [ 4:0] reg_num,
    output wire        ws_valid,
    output wire [31:0] rf_rdata,

    output wire [31:0] debug0_wb_pc,
    output wire [ 3:0] debug0_wb_rf_wen,
    output wire [ 4:0] debug0_wb_rf_wnum,
    output wire [31:0] debug0_wb_rf_wdata,
    output wire [31:0] debug0_wb_inst
);

wire reset = ~aresetn;

wire        inst_rd_req;
wire [31:0] inst_rd_addr;
wire        inst_rd_rdy;
wire        inst_ret_valid;
wire [31:0] inst_ret_data;
wire        inst_ret_last;

wire        data_rd_req;
wire [ 2:0] data_rd_size;
wire [31:0] data_rd_addr;
wire [31:0] data_rd_data;
wire        data_rd_ok;
wire        data_wr_req;
wire [ 2:0] data_wr_size;
wire [31:0] data_wr_addr;
wire [ 3:0] data_wr_strb;
wire [31:0] data_wr_data;
wire        data_wr_ok;

mycpu_top u_mycpu (
    .clk                (aclk),
    .resetn             (aresetn),
    .inst_rd_req        (inst_rd_req),
    .inst_rd_addr       (inst_rd_addr),
    .inst_rd_rdy        (inst_rd_rdy),
    .inst_ret_valid     (inst_ret_valid),
    .inst_ret_data      (inst_ret_data),
    .inst_ret_last      (inst_ret_last),
    .data_rd_req        (data_rd_req),
    .data_rd_size       (data_rd_size),
    .data_rd_addr       (data_rd_addr),
    .data_rd_data       (data_rd_data),
    .data_rd_ok         (data_rd_ok),
    .data_wr_req        (data_wr_req),
    .data_wr_size       (data_wr_size),
    .data_wr_addr       (data_wr_addr),
    .data_wr_strb       (data_wr_strb),
    .data_wr_data       (data_wr_data),
    .data_wr_ok         (data_wr_ok),
    .debug_wb_pc        (debug0_wb_pc),
    .debug_wb_inst      (debug0_wb_inst),
    .debug_wb_rf_we     (debug0_wb_rf_wen),
    .debug_wb_rf_wnum   (debug0_wb_rf_wnum),
    .debug_wb_rf_wdata  (debug0_wb_rf_wdata),
    .debug_wb1_pc       (),
    .debug_wb1_inst     (),
    .debug_wb1_rf_we    (),
    .debug_wb1_rf_wnum  (),
    .debug_wb1_rf_wdata ()
);

cpu_axi_bridge u_axi_bridge (
    .clk(aclk), .reset(reset),
    .arid(arid), .araddr(araddr), .arlen(arlen), .arsize(arsize),
    .arburst(arburst), .arlock(arlock), .arcache(arcache), .arprot(arprot),
    .arvalid(arvalid), .arready(arready),
    .rid(rid), .rdata(rdata), .rresp(rresp), .rlast(rlast), .rvalid(rvalid), .rready(rready),
    .awid(awid), .awaddr(awaddr), .awlen(awlen), .awsize(awsize),
    .awburst(awburst), .awlock(awlock), .awcache(awcache), .awprot(awprot),
    .awvalid(awvalid), .awready(awready),
    .wid(wid), .wdata(wdata), .wstrb(wstrb), .wlast(wlast), .wvalid(wvalid), .wready(wready),
    .bid(bid), .bresp(bresp), .bvalid(bvalid), .bready(bready),
    .inst_rd_req(inst_rd_req), .inst_rd_addr(inst_rd_addr), .inst_rd_rdy(inst_rd_rdy),
    .inst_ret_valid(inst_ret_valid), .inst_ret_data(inst_ret_data), .inst_ret_last(inst_ret_last),
    .data_rd_req(data_rd_req), .data_rd_size(data_rd_size), .data_rd_addr(data_rd_addr),
    .data_rd_data(data_rd_data), .data_rd_ok(data_rd_ok),
    .data_wr_req(data_wr_req), .data_wr_size(data_wr_size), .data_wr_addr(data_wr_addr),
    .data_wr_strb(data_wr_strb), .data_wr_data(data_wr_data), .data_wr_ok(data_wr_ok)
);

// These historical debug/interrupt inputs are not required by the 2026
// supervisor's no-cache baseline, but the official interface must retain them.
assign ws_valid = 1'b0;
assign rf_rdata = 32'b0;
wire unused_inputs = ^{TLBNUM[0], intrpt, break_point, infor_flag, reg_num};

endmodule
