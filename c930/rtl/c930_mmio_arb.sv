// -----------------------------------------------------------------------------
// c930_mmio_arb.sv
//
// Round-robin arbiter merging the uncached MMIO ports of two CPU cores into
// the single-port c930_mmio_bridge.  The MMIO protocol is a simple
// req/done handshake (address + data + byte strobes) with no busy signal:
// a core holds its request until done is asserted, so the arbiter serializes
// transactions and routes the response back to the granted core.
//
// ALL transactions (including the SoC-status registers HART_ID at
// 0x4000_0FF0 and CORE1_RELEASE at 0x4000_0FF4) are forwarded to the bridge,
// which intercepts those addresses and responds with its normal REGISTERED
// done timing.  This is deliberate: an arbiter-local "instant" response
// (combinational done, ~2 cycles) breaks the CPU's load pipeline, which is
// tuned for the bridge's ~5+ cycle registered-done AXI-style transactions.
//
// The requesting core's ID is passed to the bridge as o_req_core so the
// bridge can answer HART_ID reads with the correct value.
// -----------------------------------------------------------------------------
module c930_mmio_arb
(
  input  logic i_clk,
  input  logic i_rst_n,

  // ---- Core 0 MMIO port ----
  input  logic [63:0] i0_rd_addr,
  input  logic        i0_rd_req,
  output logic        o0_rd_done,
  output logic [63:0] o0_rd_data,
  input  logic [63:0] i0_wr_addr,
  input  logic [63:0] i0_wr_data,
  input  logic [7:0]  i0_wr_strobe,
  input  logic        i0_wr_valid,
  output logic        o0_wr_done,

  // ---- Core 1 MMIO port ----
  input  logic [63:0] i1_rd_addr,
  input  logic        i1_rd_req,
  output logic        o1_rd_done,
  output logic [63:0] o1_rd_data,
  input  logic [63:0] i1_wr_addr,
  input  logic [63:0] i1_wr_data,
  input  logic [7:0]  i1_wr_strobe,
  input  logic        i1_wr_valid,
  output logic        o1_wr_done,

  // ---- Merged MMIO port (to c930_mmio_bridge) ----
  output logic [63:0] o_mmio_read_addr,
  output logic        o_mmio_read_req,
  input  logic        i_mmio_read_done,
  input  logic [63:0] i_mmio_read_data,

  output logic [63:0] o_mmio_write_addr,
  output logic [63:0] o_mmio_write_data,
  output logic [7:0]  o_mmio_write_strobe,
  output logic        o_mmio_write_valid,
  input  logic        i_mmio_write_done,

  // ---- Requesting core ID (for the bridge's HART_ID register) ----
  output logic        o_req_core
);

  // -------------------------------------------------------------------------
  // Grant state machine (round-robin, holds grant until transaction done)
  // -------------------------------------------------------------------------
  typedef enum logic [1:0] {
    IDLE  = 2'd0,
    TRANS = 2'd1
  } state_t;

  state_t state;
  logic   grant;        // 0 = core0, 1 = core1
  logic   is_write;     // 0 = read, 1 = write

  logic [1:0] rr_ptr;   // round-robin pointer (only bit 0 used)

  // Request per core (read or write pending)
  wire core0_req = i0_rd_req | i0_wr_valid;
  wire core1_req = i1_rd_req | i1_wr_valid;

  // Registered grant for response routing / HART_ID
  logic grant_r;

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      state    <= IDLE;
      grant    <= 1'b0;
      grant_r  <= 1'b0;
      is_write <= 1'b0;
      rr_ptr   <= 2'd0;
    end else begin
      case (state)
        IDLE: begin
          // Round-robin: prefer the core after the last granted one
          if (rr_ptr[0] ? core1_req : core0_req) begin
            grant    <= rr_ptr[0];
            grant_r  <= rr_ptr[0];
            is_write <= rr_ptr[0] ? i1_wr_valid : i0_wr_valid;
            state    <= TRANS;
            rr_ptr   <= rr_ptr + 1'b1;
          end else if (core0_req) begin
            grant    <= 1'b0;
            grant_r  <= 1'b0;
            is_write <= i0_wr_valid;
            state    <= TRANS;
            rr_ptr   <= rr_ptr + 1'b1;
          end else if (core1_req) begin
            grant    <= 1'b1;
            grant_r  <= 1'b1;
            is_write <= i1_wr_valid;
            state    <= TRANS;
            rr_ptr   <= rr_ptr + 1'b1;
          end
        end
        TRANS: begin
          // Hold until the bridge completes the transaction
          if (is_write) begin
            if (i_mmio_write_done)
              state <= IDLE;
          end else begin
            if (i_mmio_read_done)
              state <= IDLE;
          end
        end
        default: state <= IDLE;
      endcase
    end
  end

  // -------------------------------------------------------------------------
  // Forwarding to bridge
  // -------------------------------------------------------------------------
  assign o_mmio_read_addr = grant ? i1_rd_addr : i0_rd_addr;
  assign o_mmio_read_req  = (state == TRANS) && !is_write &&
                            (grant ? i1_rd_req : i0_rd_req);

  assign o_mmio_write_addr   = grant ? i1_wr_addr   : i0_wr_addr;
  assign o_mmio_write_data   = grant ? i1_wr_data   : i0_wr_data;
  assign o_mmio_write_strobe = grant ? i1_wr_strobe : i0_wr_strobe;
  assign o_mmio_write_valid  = (state == TRANS) && is_write &&
                               (grant ? i1_wr_valid : i0_wr_valid);

  // Requesting core ID, registered at grant time (stable through TRANS)
  assign o_req_core = grant_r;

  // -------------------------------------------------------------------------
  // Response routing
  // -------------------------------------------------------------------------
  assign o0_rd_done = (state == TRANS) && !grant_r && i_mmio_read_done;
  assign o1_rd_done = (state == TRANS) &&  grant_r && i_mmio_read_done;

  assign o0_rd_data = i_mmio_read_data;
  assign o1_rd_data = i_mmio_read_data;

  assign o0_wr_done = (state == TRANS) && !grant_r && i_mmio_write_done;
  assign o1_wr_done = (state == TRANS) &&  grant_r && i_mmio_write_done;

endmodule