// -----------------------------------------------------------------------------
// c930_npu_csr.sv
//
// Control/status register file for the NPU with a simplified AXI4-Lite slave.
//
// The slave accepts one outstanding transaction at a time and pairs the AW and
// W channels (the write is committed when both AWVALID and WVALID are high).
// This is sufficient for an MMIO programming interface and mirrors the simple
// handshake style used by the reference riscv_core_axi4lite bridge.
//
// Register map (word offsets):
//   0x00 CTRL    (W) bit0 START
//   0x04 STATUS  (R) bit0 BUSY, bit1 DONE (latched), bit2 ERROR
//   0x08 DIM_M   (R/W) output rows
//   0x0C DIM_N   (R/W) output cols
//   0x10 DIM_K   (R/W) reduction length
//   0x14 A_BASE  (R/W) A matrix base address (DMA read source)
//   0x18 B_BASE  (R/W) B matrix base address (DMA read source)
//   0x1C C_BASE  (R/W) C matrix base address (DMA write sink)
//   0x20 PREC    (R/W) bit[1:0] precision: 0=INT8, 1=INT16, 2=FP16, 3=BF16
// -----------------------------------------------------------------------------
module c930_npu_csr
(
  input  logic        i_clk,
  input  logic        i_rst_n,

  // ---- AXI4-Lite slave ----
  input  logic [31:0] s_axi_awaddr,
  input  logic        s_axi_awvalid,
  output logic        s_axi_awready,
  input  logic [31:0] s_axi_wdata,
  input  logic [3:0]  s_axi_wstrb,
  input  logic        s_axi_wvalid,
  output logic        s_axi_wready,
  output logic [1:0]  s_axi_bresp,
  output logic        s_axi_bvalid,
  input  logic        s_axi_bready,

  input  logic [31:0] s_axi_araddr,
  input  logic        s_axi_arvalid,
  output logic        s_axi_arready,
  output logic [31:0] s_axi_rdata,
  output logic [1:0]  s_axi_rresp,
  output logic        s_axi_rvalid,
  input  logic        s_axi_rready,

  // ---- NPU core interface ----
  output logic        o_start,
  output logic [15:0] o_dim_m,
  output logic [15:0] o_dim_n,
  output logic [15:0] o_dim_k,
  output logic [31:0] o_a_base,
  output logic [31:0] o_b_base,
  output logic [31:0] o_c_base,
  output logic [2:0]  o_precision,
  input  logic        i_busy,
  input  logic        i_done,
  input  logic        i_error
);

  localparam logic [3:0] ADDR_CTRL     = 4'h0;
  localparam logic [3:0] ADDR_STAT     = 4'h1;
  localparam logic [3:0] ADDR_DIM_M    = 4'h2;
  localparam logic [3:0] ADDR_DIM_N    = 4'h3;
  localparam logic [3:0] ADDR_DIM_K    = 4'h4;
  localparam logic [3:0] ADDR_A_BASE   = 4'h5;
  localparam logic [3:0] ADDR_B_BASE   = 4'h6;
  localparam logic [3:0] ADDR_C_BASE   = 4'h7;
  localparam logic [3:0] ADDR_PREC     = 4'h8;

  logic [15:0] dim_m, dim_n, dim_k;
  logic [31:0] a_base, b_base, c_base;
  logic [2:0]  precision;
  logic        start_pulse;
  logic        done_latch;

  assign o_dim_m     = dim_m;
  assign o_dim_n     = dim_n;
  assign o_dim_k     = dim_k;
  assign o_a_base    = a_base;
  assign o_b_base    = b_base;
  assign o_c_base    = c_base;
  assign o_precision = precision;

  // Start only when the engine is idle.
  assign o_start = start_pulse & ~i_busy;

  // ---------------------------------------------------------------------------
  // Write channel
  // ---------------------------------------------------------------------------
  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      s_axi_awready <= 1'b0;
      s_axi_wready  <= 1'b0;
      s_axi_bvalid  <= 1'b0;
      s_axi_bresp   <= 2'b00;
      dim_m         <= 16'd0;
      dim_n         <= 16'd0;
      dim_k         <= 16'd0;
      a_base        <= 32'd0;
      b_base        <= 32'd0;
      c_base        <= 32'd0;
      precision     <= 3'd0;
      start_pulse   <= 1'b0;
      done_latch    <= 1'b0;
    end else begin
      start_pulse <= 1'b0;

      if (i_done)
        done_latch <= 1'b1;

      if (s_axi_bvalid && s_axi_bready)
        s_axi_bvalid <= 1'b0;

      s_axi_awready <= 1'b0;
      s_axi_wready  <= 1'b0;

      if (s_axi_awvalid && s_axi_wvalid && !s_axi_bvalid) begin
        s_axi_awready <= 1'b1;
        s_axi_wready  <= 1'b1;

        case (s_axi_awaddr[5:2])
          ADDR_CTRL: begin
            if (s_axi_wstrb[0] && s_axi_wdata[0]) begin
              start_pulse <= 1'b1;
              done_latch  <= 1'b0;
            end
          end
          ADDR_DIM_M:  if (s_axi_wstrb[0]) dim_m <= s_axi_wdata[15:0];
          ADDR_DIM_N:  if (s_axi_wstrb[0]) dim_n <= s_axi_wdata[15:0];
          ADDR_DIM_K:  if (s_axi_wstrb[0]) dim_k <= s_axi_wdata[15:0];
          ADDR_A_BASE: if (s_axi_wstrb[0]) a_base <= s_axi_wdata;
          ADDR_B_BASE: if (s_axi_wstrb[0]) b_base <= s_axi_wdata;
          ADDR_C_BASE: if (s_axi_wstrb[0]) c_base <= s_axi_wdata;
          ADDR_PREC:   if (s_axi_wstrb[0]) precision <= s_axi_wdata[2:0];
          default: ;
        endcase

        s_axi_bvalid <= 1'b1;
        s_axi_bresp  <= 2'b00;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Read channel
  // ---------------------------------------------------------------------------
  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      s_axi_arready <= 1'b0;
      s_axi_rvalid  <= 1'b0;
      s_axi_rdata   <= 32'd0;
      s_axi_rresp   <= 2'b00;
    end else begin
      s_axi_arready <= 1'b0;

      if (s_axi_rvalid && s_axi_rready)
        s_axi_rvalid <= 1'b0;

      if (s_axi_arvalid && !s_axi_rvalid) begin
        s_axi_arready <= 1'b1;

        case (s_axi_araddr[5:2])
          ADDR_STAT:   s_axi_rdata <= {29'd0, i_error, done_latch, i_busy};
          ADDR_DIM_M:  s_axi_rdata <= {16'd0, dim_m};
          ADDR_DIM_N:  s_axi_rdata <= {16'd0, dim_n};
          ADDR_DIM_K:  s_axi_rdata <= {16'd0, dim_k};
          ADDR_A_BASE: s_axi_rdata <= a_base;
          ADDR_B_BASE: s_axi_rdata <= b_base;
          ADDR_C_BASE: s_axi_rdata <= c_base;
          ADDR_PREC:   s_axi_rdata <= {29'd0, precision};
          default:     s_axi_rdata <= 32'd0;
        endcase

        s_axi_rvalid <= 1'b1;
        s_axi_rresp  <= 2'b00;
      end
    end
  end

endmodule
