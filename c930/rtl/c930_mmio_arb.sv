// -----------------------------------------------------------------------------
// c930_mmio_arb.sv
//
// Round-robin arbiter merging the uncached MMIO ports of four CPU cores into
// the single-port c930_mmio_bridge.  The MMIO protocol is a simple
// req/done handshake (address + data + byte strobes) with no busy signal:
// a core holds its request until done is asserted, so the arbiter serializes
// transactions and routes the response back to the granted core.
//
// ALL transactions (including the SoC-status registers HART_ID at
// 0x4000_0FF0 and the per-core RELEASE registers at 0x4000_0FF4/8/C) are
// forwarded to the bridge, which intercepts those addresses and responds
// with its normal REGISTERED done timing.
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

  // ---- Core 2 MMIO port ----
  input  logic [63:0] i2_rd_addr,
  input  logic        i2_rd_req,
  output logic        o2_rd_done,
  output logic [63:0] o2_rd_data,
  input  logic [63:0] i2_wr_addr,
  input  logic [63:0] i2_wr_data,
  input  logic [7:0]  i2_wr_strobe,
  input  logic        i2_wr_valid,
  output logic        o2_wr_done,

  // ---- Core 3 MMIO port ----
  input  logic [63:0] i3_rd_addr,
  input  logic        i3_rd_req,
  output logic        o3_rd_done,
  output logic [63:0] o3_rd_data,
  input  logic [63:0] i3_wr_addr,
  input  logic [63:0] i3_wr_data,
  input  logic [7:0]  i3_wr_strobe,
  input  logic        i3_wr_valid,
  output logic        o3_wr_done,

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
  output logic [1:0]  o_req_core
);

  // -------------------------------------------------------------------------
  // Grant state machine (round-robin, holds grant until transaction done)
  // -------------------------------------------------------------------------
  typedef enum logic [1:0] {
    IDLE  = 2'd0,
    TRANS = 2'd1
  } state_t;

  state_t state;
  logic [1:0] grant;      // owning core 0..3
  logic       is_write;   // 0 = read, 1 = write

  logic [1:0] rr_ptr;     // round-robin pointer

  // Request per core (read or write pending)
  wire core0_req = i0_rd_req | i0_wr_valid;
  wire core1_req = i1_rd_req | i1_wr_valid;
  wire core2_req = i2_rd_req | i2_wr_valid;
  wire core3_req = i3_rd_req | i3_wr_valid;
  wire [3:0] req_v = {core3_req, core2_req, core1_req, core0_req};

  // Registered grant for response routing / HART_ID
  logic [1:0] grant_r;

  // Combinational next-grant: first requesting core at/after rr_ptr
  logic [1:0] next_owner;
  logic       have_grant;
  always_comb begin
    next_owner = '0;
    have_grant = 1'b0;
    // First requesting core at/after rr_ptr (wrapping).  have_grant guards
    // the remaining iterations once the first match is latched (an unrolled
    // break -- iverilog rejects `break` in always_comb).
    for (int i = 0; i < 4; i++) begin
      if (!have_grant && req_v[(rr_ptr + i) % 4]) begin
        next_owner = (rr_ptr + i) % 4;
        have_grant = 1'b1;
      end
    end
  end

  logic [63:0] rd_addr_v [4];
  logic [63:0] wr_addr_v [4];
  logic [63:0] wr_data_v [4];
  logic [7:0]  wr_strb_v [4];
  logic [3:0]  wr_val_v;
  logic [3:0]  rd_req_v;
  assign rd_addr_v[0] = i0_rd_addr; assign rd_addr_v[1] = i1_rd_addr;
  assign rd_addr_v[2] = i2_rd_addr; assign rd_addr_v[3] = i3_rd_addr;
  assign wr_addr_v[0] = i0_wr_addr; assign wr_addr_v[1] = i1_wr_addr;
  assign wr_addr_v[2] = i2_wr_addr; assign wr_addr_v[3] = i3_wr_addr;
  assign wr_data_v[0] = i0_wr_data; assign wr_data_v[1] = i1_wr_data;
  assign wr_data_v[2] = i2_wr_data; assign wr_data_v[3] = i3_wr_data;
  assign wr_strb_v[0] = i0_wr_strobe; assign wr_strb_v[1] = i1_wr_strobe;
  assign wr_strb_v[2] = i2_wr_strobe; assign wr_strb_v[3] = i3_wr_strobe;
  assign wr_val_v = {i3_wr_valid, i2_wr_valid, i1_wr_valid, i0_wr_valid};
  assign rd_req_v = {i3_rd_req, i2_rd_req, i1_rd_req, i0_rd_req};

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      state    <= IDLE;
      grant    <= '0;
      grant_r  <= '0;
      is_write <= 1'b0;
      rr_ptr   <= '0;
    end else begin
      case (state)
        IDLE: begin
          if (have_grant) begin
            grant    <= next_owner;
            grant_r  <= next_owner;
            is_write <= wr_val_v[next_owner];
            state    <= TRANS;
            rr_ptr   <= next_owner + 1'b1;
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
  assign o_mmio_read_addr = rd_addr_v[grant];
  assign o_mmio_read_req  = (state == TRANS) && !is_write && rd_req_v[grant];

  assign o_mmio_write_addr   = wr_addr_v[grant];
  assign o_mmio_write_data   = wr_data_v[grant];
  assign o_mmio_write_strobe = wr_strb_v[grant];
  assign o_mmio_write_valid  = (state == TRANS) && is_write && wr_val_v[grant];

  // Requesting core ID, registered at grant time (stable through TRANS)
  assign o_req_core = grant_r;

  // -------------------------------------------------------------------------
  // Response routing
  // -------------------------------------------------------------------------
  assign o0_rd_done = (state == TRANS) && (grant_r == 2'd0) && i_mmio_read_done;
  assign o1_rd_done = (state == TRANS) && (grant_r == 2'd1) && i_mmio_read_done;
  assign o2_rd_done = (state == TRANS) && (grant_r == 2'd2) && i_mmio_read_done;
  assign o3_rd_done = (state == TRANS) && (grant_r == 2'd3) && i_mmio_read_done;

  assign o0_rd_data = i_mmio_read_data;
  assign o1_rd_data = i_mmio_read_data;
  assign o2_rd_data = i_mmio_read_data;
  assign o3_rd_data = i_mmio_read_data;

  assign o0_wr_done = (state == TRANS) && (grant_r == 2'd0) && i_mmio_write_done;
  assign o1_wr_done = (state == TRANS) && (grant_r == 2'd1) && i_mmio_write_done;
  assign o2_wr_done = (state == TRANS) && (grant_r == 2'd2) && i_mmio_write_done;
  assign o3_wr_done = (state == TRANS) && (grant_r == 2'd3) && i_mmio_write_done;

endmodule
