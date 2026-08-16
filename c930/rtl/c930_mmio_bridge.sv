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

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n)
      state <= IDLE;
    else
      state <= next_state;
  end

  // Registered completion pulses: break any combinational coupling between the
  // done signals and the dcache's o_mmio_{read,write}_* (the dcache FSM clears
  // its request/valid combinationally from done, so done must be a clean flop).
  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      done_ff  <= 1'b0;
      rdone_ff <= 1'b0;
    end else begin
      done_ff  <= (state == W_B) && m_axi_bvalid;
      rdone_ff <= (state == R_R) && m_axi_rvalid;
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
    o_mmio_read_data  = {32'd0, m_axi_rdata};
    o_mmio_write_done = done_ff;

    case (state)
      IDLE: begin
        if (i_mmio_write_valid) begin
          m_axi_awaddr  = i_mmio_write_addr[31:0];
          m_axi_wdata   = i_mmio_write_data[31:0];
          m_axi_wstrb   = i_mmio_write_strobe[7:4] != 4'b0 ? 4'hF : i_mmio_write_strobe[3:0];
          m_axi_awvalid = 1'b1;
          m_axi_wvalid  = 1'b1;
          next_state    = W_AW_W;
        end else if (i_mmio_read_req) begin
          m_axi_araddr  = i_mmio_read_addr[31:0];
          m_axi_arvalid = 1'b1;
          next_state    = R_AR;
        end
      end

      W_AW_W: begin
        m_axi_awaddr  = awaddr_r;
        m_axi_wdata   = wdata_r;
        m_axi_wstrb   = wstrb_r;
        m_axi_awvalid = 1'b1;
        m_axi_wvalid  = 1'b1;
        if (m_axi_awready && m_axi_wready)
          next_state = W_B;
      end

      W_B: begin
        m_axi_bready = 1'b1;
        if (!i_mmio_write_valid)
          next_state = IDLE;
      end

      R_AR: begin
        m_axi_araddr  = araddr_r;
        m_axi_arvalid = 1'b1;
        if (m_axi_arready)
          next_state = R_R;
      end

      R_R: begin
        m_axi_rready = 1'b1;
        o_mmio_read_data = {32'd0, m_axi_rdata};
        if (!i_mmio_read_req)
          next_state = IDLE;
      end

      default: next_state = IDLE;
    endcase
  end

  // Latch the transaction fields when they are accepted in IDLE.
  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      awaddr_r <= 32'd0;
      araddr_r <= 32'd0;
      wdata_r  <= 32'd0;
      wstrb_r  <= 4'hF;
    end else if (state == IDLE) begin
      if (i_mmio_write_valid) begin
        awaddr_r <= i_mmio_write_addr[31:0];
        wdata_r  <= i_mmio_write_data[31:0];
        wstrb_r  <= i_mmio_write_strobe[7:4] != 4'b0 ? 4'hF : i_mmio_write_strobe[3:0];
      end else if (i_mmio_read_req) begin
        araddr_r <= i_mmio_read_addr[31:0];
      end
    end
  end

endmodule
