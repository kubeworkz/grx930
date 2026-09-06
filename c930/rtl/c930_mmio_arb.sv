// -----------------------------------------------------------------------------
// c930_mmio_arb.sv
//
// Round-robin arbiter merging the uncached MMIO ports of two CPU cores into
// the single-port c930_mmio_bridge.  The MMIO protocol is a simple
// req/done handshake (address + data + byte strobes) with no busy signal:
// a core holds its request until done is asserted, so the arbiter serializes
// transactions and routes the response back to the granted core.
//
// Also implements a HART_ID register at 0x4000_0FF0 (read-only): a read
// returns the requesting core's ID (0 or 1) without touching the bridge.
// This lets shared boot firmware branch on the calling core.  Writes to
// HART_ID are ignored (completed immediately).
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
  input  logic        i_mmio_write_done
);

  localparam logic [63:0] HART_ID_ADDR = 64'h4000_0FF0;

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
  logic   is_hart;      // current transaction is the HART_ID register

  logic [1:0] rr_ptr;   // round-robin pointer (only bit 0 used)

  // Request per core (read or write pending)
  wire core0_req = i0_rd_req | i0_wr_valid;
  wire core1_req = i1_rd_req | i1_wr_valid;

  // Registered grant for response routing
  logic grant_r;

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      state   <= IDLE;
      grant   <= 1'b0;
      grant_r <= 1'b0;
      is_write<= 1'b0;
      is_hart <= 1'b0;
      rr_ptr  <= 2'd0;
    end else begin
      case (state)
        IDLE: begin
          // Round-robin: prefer the core after the last granted one
          if (rr_ptr[0] ? core1_req : core0_req) begin
            grant    <= rr_ptr[0];
            grant_r  <= rr_ptr[0];
            is_write <= rr_ptr[0] ? i1_wr_valid : i0_wr_valid;
            // HART_ID check on the winning core's address
            if (rr_ptr[0]) begin
              is_hart <= (i1_rd_req && i1_rd_addr == HART_ID_ADDR) ||
                         (i1_wr_valid && i1_wr_addr == HART_ID_ADDR);
            end else begin
              is_hart <= (i0_rd_req && i0_rd_addr == HART_ID_ADDR) ||
                         (i0_wr_valid && i0_wr_addr == HART_ID_ADDR);
            end
            state   <= TRANS;
            rr_ptr  <= rr_ptr + 1'b1;
          end else if (core0_req) begin
            grant    <= 1'b0;
            grant_r  <= 1'b0;
            is_write <= i0_wr_valid;
            is_hart  <= (i0_rd_req && i0_rd_addr == HART_ID_ADDR) ||
                        (i0_wr_valid && i0_wr_addr == HART_ID_ADDR);
            state    <= TRANS;
            rr_ptr   <= rr_ptr + 1'b1;
          end else if (core1_req) begin
            grant    <= 1'b1;
            grant_r  <= 1'b1;
            is_write <= i1_wr_valid;
            is_hart  <= (i1_rd_req && i1_rd_addr == HART_ID_ADDR) ||
                        (i1_wr_valid && i1_wr_addr == HART_ID_ADDR);
            state    <= TRANS;
            rr_ptr   <= rr_ptr + 1'b1;
          end
        end
        TRANS: begin
          // Hold until the bridge (or HART_ID logic) completes the transaction
          if (is_hart) begin
            state <= IDLE;  // one-cycle HART_ID response
          end else if (is_write) begin
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
  // Read: granted core's address/request, or the HART_ID path (no bridge)
  assign o_mmio_read_addr = grant ? i1_rd_addr : i0_rd_addr;
  assign o_mmio_read_req  = (state == TRANS) && !is_write && !is_hart &&
                            (grant ? i1_rd_req : i0_rd_req);

  // Write: granted core's data path
  assign o_mmio_write_addr   = grant ? i1_wr_addr   : i0_wr_addr;
  assign o_mmio_write_data   = grant ? i1_wr_data   : i0_wr_data;
  assign o_mmio_write_strobe = grant ? i1_wr_strobe : i0_wr_strobe;
  assign o_mmio_write_valid  = (state == TRANS) && is_write && !is_hart &&
                               (grant ? i1_wr_valid : i0_wr_valid);

  // -------------------------------------------------------------------------
  // Response routing
  // -------------------------------------------------------------------------
  // Read done: bridge done (routed to granted core), or HART_ID one-shot
  assign o0_rd_done = (state == TRANS) && !grant_r && (is_hart || i_mmio_read_done);
  assign o1_rd_done = (state == TRANS) &&  grant_r && (is_hart || i_mmio_read_done);

  // HART_ID data: core ID in [31:0]; otherwise bridge read data
  wire [63:0] hart_data = 64'h0000_0000_0000_0000 | grant_r;
  assign o0_rd_data = is_hart ? hart_data : i_mmio_read_data;
  assign o1_rd_data = is_hart ? hart_data : i_mmio_read_data;

  // Write done: bridge done (or one-shot for HART_ID writes)
  assign o0_wr_done = (state == TRANS) && !grant_r && (is_hart || i_mmio_write_done);
  assign o1_wr_done = (state == TRANS) &&  grant_r && (is_hart || i_mmio_write_done);

endmodule