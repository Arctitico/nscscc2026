// ============================================================================
// Instruction Decode
// ============================================================================
module ID (
    input  wire             clk,
    input  wire             reset,
    input  wire             flush,

    input  wire             IF_to_ID_valid,
    input  wire             RR_allow_in,
    output wire             ID_allow_in,
    output wire             ID_to_RR_valid,

    input  if_to_id_bus_t   IF_to_ID_BUS,
    output id_to_rr_bus_t   ID_to_RR_BUS
);

reg            id_valid;
if_to_id_bus_t id_bus_r;        // pc, inst

wire id_ready_go = 1'b1;
assign ID_allow_in    = ~id_valid | (id_ready_go & RR_allow_in);
assign ID_to_RR_valid =  id_valid &  id_ready_go;

always @(posedge clk or posedge reset) begin
    if (reset)            id_valid <= 1'b0;
    else if (flush)       id_valid <= 1'b0;
    else if (ID_allow_in) id_valid <= IF_to_ID_valid;
end

always @(posedge clk or posedge reset) begin
    if (reset)                             id_bus_r <= '0;
    else if (IF_to_ID_valid & ID_allow_in) id_bus_r <= IF_to_ID_BUS;
end

d_bus_t d_bus;
decoder u_decoder(
    .inst  (id_bus_r.inst),
    .d_bus (d_bus        )
);

assign ID_to_RR_BUS = '{pc: id_bus_r.pc, d_bus: d_bus};

endmodule
