// -----------------------------------------------------------------------------
// c930_mmio_bridge.sv
//
// Adapts the CPU core's uncached MMIO port (64-bit address/data with byte
// strobes, simple request/valid <-> done handshake) to the NPU's 32-bit
// AXI4-Lite control/status slave.
//
// The C program performs 32-bit lwu/sw to word-aligned MMIO addresses, so the
// bridge always passes the low 32 bits of the data and the low 32 bits of the
// byte address (the CSR slave decodes word offset from addr[5:2]).
//
// SoC-status registers are intercepted HERE (not in the arbiter) so they use
// the same REGISTERED done timing as a real AXI round trip:
//   0x4000_0FF0  HART_ID        (read-only: returns the requesting core ID)
//   0x4000_0FF4  CORE1_RELEASE  (write: CPU0 arms CPU1's worker entry addr;
//                                read: CPU1's boot-ROM parking loop polls it)
// The requesting core ID arrives on i_hart_id (from c930_mmio_arb).
// -----------------------------------------------------------------------------
module c930_mmio_bridge
(
  input  logic i_clk,
  input  logic i_rst_n,

  // ---- CPU MMIO port (from riscv_core dcache, uncached region) ----
  input  logic [63:0] i_mmio_read_addr,
  input  logic        i_mmio_read_req,
  output logic        o_mmio_read_done,
  output logic [63:0] o_mmio_read_data,   // 32-bit result in [31:0]

  input  logic [63:0] i_mmio_write_addr,
  input  logic [63:0] i_mmio_write_data,
  input  logic [7:0]  i_mmio_write_strobe,
  input  logic        i_mmio_write_valid,
  output logic        o_mmio_write_done,

  // ---- Requesting core ID (0/1), for the HART_ID register ----
  input  logic        i_hart_id,

  // ---- AXI4-Lite master (toward c930_npu_csr) ----
  output logic [31:0] m_axi_awaddr,
  output logic        m_axi_awvalid,
  input  logic        m_axi_awready,
  output logic [31:0] m_axi_wdata,
  output logic [3:0]  m_axi_wstrb,
  output logic        m_axi_wvalid,
  input  logic        m_axi_wready,
  input  logic [1:0]  m_axi_bresp,
  input  logic        m_axi_bvalid,
  output logic        m_axi_bready,
  output logic [31:0] m_axi_araddr,
  output logic        m_axi_arvalid,
  input  logic        m_axi_arready,
  input  logic [31:0] m_axi_rdata,
  input  logic [1:0]  m_axi_rresp,
  input  logic        m_axi_rvalid,
  output logic        m_axi_rready
);

  localparam logic [31:0] HART_ID_ADDR      = 32'h4000_0FF0;
  localparam logic [31:0] CORE1_RELEASE_ADDR = 32'h4000_0FF4;

  typedef enum logic [2:0] {
    IDLE   = 3'd0,
    W_AW_W = 3'd1,
    W_B    = 3'd2,
    R_AR   = 3'd3,
    R_R    = 3'd4
  } state_t;

  state_t state, next_state;

  logic [31:0] awaddr_r, araddr_r, wdata_r;
  logic [3:0]  wstrb_r;
  logic        done_ff, rdone_ff;

  // Independent AW/W handshake tracking.  AXI4 slaves may accept the write
  // address and the write data on different cycles (the UART asserts awready
  // in AXI_IDLE and wready only in AXI_WR, one cycle later -- never
  // simultaneously), so W_AW_W must latch each channel's completion
  // separately instead of waiting for awready && wready to co-assert.
  logic        aw_ok, w_ok;

  // SoC-status registers (intercepted here, serviced with the bridge's normal
  // registered-done timing)
  logic [31:0] release_val;
  logic        wr_special;   // current write targets RELEASE (no AXI needed)
  logic        rd_special;   // current read targets HART_ID/RELEASE
  logic        rd_hart;      // ...specifically HART_ID (vs RELEASE read)

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n)
      state <= IDLE;
    else
      state <= next_state;
  end

  // Registered completion pulses: break any combinational coupling between the
  // done signals and the dcache's o_mmio_{read,write}_* (the dcache FSM clears
  // its request/valid combinationally from done, so done must be a clean flop).
  // Special (intercepted) transactions complete on the same flops: the flag is
  // set in IDLE and acts as a fake bvalid/rvalid, so the done pulse has the
  // same shape and latency as a real AXI round trip.
  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      done_ff  <= 1'b0;
      rdone_ff <= 1'b0;
      aw_ok    <= 1'b0;
      w_ok     <= 1'b0;
    end else begin
      done_ff  <= (state == W_B) && (m_axi_bvalid || wr_special);
      rdone_ff <= (state == R_R) && (m_axi_rvalid || rd_special);
      // Latch each channel handshake as it completes; cleared once the
      // transaction leaves W_AW_W (see IDLE capture block below).
      if (state == W_AW_W) begin
        if (m_axi_awready) aw_ok <= 1'b1;
        if (m_axi_wready)  w_ok  <= 1'b1;
      end
    end
  end

  always_comb begin
    next_state = state;

    // Defaults. Note bready/rready are asserted ONLY in the response states:
    // the CSR slave clears bvalid/rvalid when it sees the ready side high, so
    // asserting ready earlier would kill the response pulse before this bridge
    // reaches the state that observes it.
    m_axi_awaddr  = awaddr_r;
    m_axi_awvalid = 1'b0;
    m_axi_wdata   = wdata_r;
    m_axi_wstrb   = wstrb_r;
    m_axi_wvalid  = 1'b0;
    m_axi_bready  = 1'b0;
    m_axi_araddr  = araddr_r;
    m_axi_arvalid = 1'b0;
    m_axi_rready  = 1'b0;

    o_mmio_read_done  = rdone_ff;
    o_mmio_read_data  = rd_special ? (rd_hart ? {32'd0, 32'h0000_0000 | i_hart_id}
                                              : {32'd0, release_val})
                                   : {32'd0, m_axi_rdata};
    o_mmio_write_done = done_ff;

    case (state)
      IDLE: begin
        // Capture the request fields and advance to the AXI-issue state. The
        // request is deliberately NOT presented combinationally here: the old
        // code strobed awvalid/wvalid/wstrb straight off i_mmio_write_valid,
        // putting the dcache's combinational address -> write-valid decode
        // (VALID_MEM/tag lookup, byte-strobe decoder, FSM) on the NPU CSR's
        // clock-enable critical path. W_AW_W / R_AR issue the channels from
        // the REGISTERED awaddr_r/wdata_r/wstrb_r one cycle later, so the
        // a_base CE cone starts at a flop. The dcache holds its request as a
        // level until done, so the extra cycle is invisible to software.
        if (i_mmio_write_valid) begin
          next_state = W_AW_W;
        end else if (i_mmio_read_req) begin
          next_state = R_AR;
        end
      end

      W_AW_W: begin
        if (!wr_special) begin
          m_axi_awaddr  = awaddr_r;
          m_axi_wdata   = wdata_r;
          m_axi_wstrb   = wstrb_r;
          // Assert each channel until ITS handshake completes (deasserting
          // awvalid once awready has been seen prevents a slave that returns
          // to IDLE from accepting a second, duplicate write address).
          m_axi_awvalid = !aw_ok;
          m_axi_wvalid  = !w_ok;
          if ((aw_ok || m_axi_awready) && (w_ok || m_axi_wready))
            next_state = W_B;
        end else begin
          // Intercepted write: no AXI master traffic; same state latency.
          next_state = W_B;
        end
      end

      W_B: begin
        m_axi_bready = 1'b1;
        // Special writes exit on the done pulse itself (one cycle in W_B).
        // Exiting on the wr_special flag alone would put the bridge one cycle
        // AHEAD of the arbiter (which exits on the REGISTERED done_ff), so the
        // bridge would see the still-presented request while the arbiter is
        // still in TRANS and double-book the same transaction.  Exiting on
        // done_ff keeps both FSMs on the same edge and makes the pulse exactly
        // one cycle, so it cannot leak into the next granted transaction.
        if (wr_special ? done_ff : !i_mmio_write_valid)
          next_state = IDLE;
      end

      R_AR: begin
        if (!rd_special) begin
          m_axi_araddr  = araddr_r;
          m_axi_arvalid = 1'b1;
          if (m_axi_arready)
            next_state = R_R;
        end else begin
          // Intercepted read: no AXI master traffic; same state latency.
          next_state = R_R;
        end
      end

      R_R: begin
        m_axi_rready = 1'b1;
        o_mmio_read_data = rd_special ? (rd_hart ? {32'd0, 32'h0000_0000 | i_hart_id}
                                                  : {32'd0, release_val})
                                      : {32'd0, m_axi_rdata};
        // Special reads exit on the done pulse -- see W_B note: this keeps
        // the bridge and arbiter on the same exit edge and makes the pulse
        // exactly one cycle so it cannot leak into the next transaction.
        if (rd_special ? rdone_ff : !i_mmio_read_req)
          next_state = IDLE;
      end

      default: next_state = IDLE;
    endcase
  end

  // Latch the transaction fields when IDLE first sees the request. The dcache
  // freezes its EX/MEM pipe (o_stall=1) during MMIO transactions AND during the
  // MMIO_DRAIN gap, so by the time IDLE re-asserts the request the fields are
  // stable and there is no race with the pipe update. The registered completion
  // pulses above still break the combinational done->request loop.
  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      awaddr_r     <= 32'd0;
      araddr_r     <= 32'd0;
      wdata_r      <= 32'd0;
      wstrb_r      <= 4'hF;
      release_val  <= 32'd0;
      wr_special   <= 1'b0;
      rd_special   <= 1'b0;
      rd_hart      <= 1'b0;
    end else if (state == IDLE) begin
      aw_ok <= 1'b0;
      w_ok  <= 1'b0;
      if (i_mmio_write_valid) begin
        awaddr_r <= i_mmio_write_addr[31:0];
        wdata_r  <= i_mmio_write_data[31:0];
        wstrb_r  <= i_mmio_write_strobe[7:4] != 4'b0 ? 4'hF : i_mmio_write_strobe[3:0];
        wr_special <= (i_mmio_write_addr[31:0] == CORE1_RELEASE_ADDR);
        if (i_mmio_write_addr[31:0] == CORE1_RELEASE_ADDR)
          release_val <= i_mmio_write_data[31:0];
      end else if (i_mmio_read_req) begin
        araddr_r <= i_mmio_read_addr[31:0];
        rd_special <= (i_mmio_read_addr[31:0] == HART_ID_ADDR) ||
                      (i_mmio_read_addr[31:0] == CORE1_RELEASE_ADDR);
        rd_hart    <= (i_mmio_read_addr[31:0] == HART_ID_ADDR);
      end
    end
  end

endmodule