// =============================================================================
// c930_aplic.sv — Minimal RISC-V AIA APLIC (Advanced PLIC)
//
// 3-source interrupt controller for the C930 SoC:
//     source 1 = NPU0 completion        (edge — NPU o_irq is a 1-cycle pulse)
//     source 2 = NPU1 completion        (edge)
//     source 3 = UART RX/TX interrupt   (level)
//
// Register map (APLIC_BASE = 0x4000_4000):
//     +0x00  source_priority[1]   bits[3:0]  (NPU0)
//     +0x04  source_priority[2]   bits[3:0]  (NPU1)
//     +0x08  source_priority[3]   bits[3:0]  (UART)
//     +0x0C  enable_m             bits[3:1]  (machine-level enable)
//     +0x10  threshold            bits[3:0]  (min priority that may interrupt;
//                                             a source must be strictly above)
//     +0x14  claim/complete:      read  = claim highest-priority pending
//                                          source (returns source index 1..3,
//                                          0 if none); edge sources clear
//                                          pending on claim
//                                 write = complete: clear in-service for the
//                                          source index in bits[2:0]
//     +0x18  sourcecfg[1]  bits[1:0]  0=disabled 1=level  2=rising-edge
//     +0x1C  sourcecfg[2]  bits[1:0]  (same)
//     +0x20  sourcecfg[3]  bits[1:0]  (same)
//
// Semantics:
//   * A source is "eligible" when enabled (sourcecfg != 0 and enable_m bit set),
//     pending, priority > threshold, and not in-service.
//   * o_irq = OR of all eligible sources.  The CPU core feeds this straight
//     into its machine-external-interrupt input (mie.MEIE / mstatus.MIE gate
//     delivery in the core).
//   * Claim (read +0x14) returns the highest-priority eligible source;
//     ties go to the lowest source index.  Claiming sets in-service and (for
//     edge sources) clears pending.
//   * Complete (write +0x14) clears in-service for the written source.
//     A level source whose line is still high re-asserts o_irq after
//     complete (the ISR must clear the source to stop it).
//
// AXI4-Lite slave matching c930_npu_csr's handshake (AW+W co-valid in a
// single cycle, single-cycle AR accept).
// =============================================================================

module c930_aplic (
  input  logic        i_clk,
  input  logic        i_rst_n,

  // ---- IRQ sources (level inputs; edge sources are captured on rising edge)
  input  logic        i_irq_npu0,
  input  logic        i_irq_npu1,
  input  logic        i_irq_uart,

  // ---- Machine external interrupt to CPU(s)
  output logic        o_irq,

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
  input  logic        s_axi_rready
);

  // ---------------------------------------------------------------------------
  // Source config registers (scalars; indices map 1=NPU0 2=NPU1 3=UART)
  // ---------------------------------------------------------------------------
  logic [3:0] prio_1, prio_2, prio_3;
  logic       en_1,  en_2,  en_3;
  logic [1:0] scfg_1, scfg_2, scfg_3;
  logic [3:0] threshold;

  logic       pnd_1, pnd_2, pnd_3;   // captured pending state
  logic       isv_1, isv_2, isv_3;   // claimed, awaiting complete

  // ---------------------------------------------------------------------------
  // Source inputs + edge detect (raw_d is the registered delay)
  // ---------------------------------------------------------------------------
  logic raw_d_1, raw_d_2, raw_d_3;
  wire  edge_1 = i_irq_npu0 && !raw_d_1;
  wire  edge_2 = i_irq_npu1 && !raw_d_2;
  wire  edge_3 = i_irq_uart && !raw_d_3;

  // Eligibility: enabled mode + enable_m + pending + prio>threshold + not busy
  wire elig_1 = (scfg_1 != 2'd0) && en_1 && pnd_1 && (prio_1 > threshold) && !isv_1;
  wire elig_2 = (scfg_2 != 2'd0) && en_2 && pnd_2 && (prio_2 > threshold) && !isv_2;
  wire elig_3 = (scfg_3 != 2'd0) && en_3 && pnd_3 && (prio_3 > threshold) && !isv_3;

  assign o_irq = elig_1 || elig_2 || elig_3;

  // ---------------------------------------------------------------------------
  // Priority encoder: highest priority wins; tie -> lowest source index.
  // ---------------------------------------------------------------------------
  logic [1:0] sel_high;
  always_comb begin
    if (elig_1)      sel_high = 2'd1;
    else if (elig_2) sel_high = 2'd2;
    else if (elig_3) sel_high = 2'd3;
    else             sel_high = 2'd0;
  end

  // ---------------------------------------------------------------------------
  // Claim: an accepted read of +0x14. The read channel registers a 1-cycle
  // claim event (with the claimed source index) so the side effects below land
  // deterministically in the main state machine.
  // ---------------------------------------------------------------------------
  logic claim_evt;      // 1-cycle pulse: a claim read was accepted
  logic [1:0] claim_src; // source index of that claim (0 if none eligible)

  // ---------------------------------------------------------------------------
  // Main state update
  // ---------------------------------------------------------------------------
  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      prio_1 <= 4'd0;  prio_2 <= 4'd0;  prio_3 <= 4'd0;
      en_1 <= 1'b0;    en_2 <= 1'b0;    en_3 <= 1'b0;
      scfg_1 <= 2'd2;  // edge capture by default: NPU IRQs are completion pulses
      scfg_2 <= 2'd2;
      scfg_3 <= 2'd1;  // level capture: UART IRQ holds while data is pending
      threshold <= 4'd0;
      raw_d_1 <= 1'b0; raw_d_2 <= 1'b0; raw_d_3 <= 1'b0;
      pnd_1 <= 1'b0;   pnd_2 <= 1'b0;   pnd_3 <= 1'b0;
      isv_1 <= 1'b0;   isv_2 <= 1'b0;   isv_3 <= 1'b0;
      s_axi_awready <= 1'b0;
      s_axi_wready  <= 1'b0;
      s_axi_bvalid  <= 1'b0;
    end else begin
      // ---- AXI write channel: register writes and complete (+0x14) ----
      s_axi_awready <= 1'b0;
      s_axi_wready  <= 1'b0;
      if (s_axi_bvalid && s_axi_bready)
        s_axi_bvalid <= 1'b0;

      if (s_axi_awvalid && s_axi_wvalid && !s_axi_bvalid) begin
        s_axi_awready <= 1'b1;
        s_axi_wready  <= 1'b1;
        s_axi_bvalid  <= 1'b1;
        s_axi_bresp   <= 2'b00;
        if (s_axi_wstrb[0]) begin
          case (s_axi_awaddr[7:0])
            8'h00: prio_1    <= s_axi_wdata[3:0];
            8'h04: prio_2    <= s_axi_wdata[3:0];
            8'h08: prio_3    <= s_axi_wdata[3:0];
            8'h0C: begin
                     en_1 <= s_axi_wdata[1];
                     en_2 <= s_axi_wdata[2];
                     en_3 <= s_axi_wdata[3];
                   end
            8'h10: threshold <= s_axi_wdata[3:0];
            8'h18: scfg_1    <= s_axi_wdata[1:0];
            8'h1C: scfg_2    <= s_axi_wdata[1:0];
            8'h20: scfg_3    <= s_axi_wdata[1:0];
            // +0x14: complete (handled below)
            default: ;
          endcase

          // Complete: clear in-service for the written source index.
          case (s_axi_awaddr[7:0])
            8'h14: case (s_axi_wdata[2:0])
                     3'd1: isv_1 <= 1'b0;
                     3'd2: isv_2 <= 1'b0;
                     3'd3: isv_3 <= 1'b0;
                     default: ;
                   endcase
            default: ;
          endcase
        end
      end

      // ---- Edge/level capture ----
      raw_d_1 <= i_irq_npu0;
      raw_d_2 <= i_irq_npu1;
      raw_d_3 <= i_irq_uart;

      // Source 1 (NPU0)
      case (scfg_1)
        2'd0:    pnd_1 <= 1'b0;                        // disabled
        2'd1:    pnd_1 <= i_irq_npu0;                  // level: track the line
        default: begin                                 // edge
                   if (edge_1) pnd_1 <= 1'b1;
                 end
      endcase
      // Source 2 (NPU1)
      case (scfg_2)
        2'd0:    pnd_2 <= 1'b0;
        2'd1:    pnd_2 <= i_irq_npu1;
        default: begin
                   if (edge_2) pnd_2 <= 1'b1;
                 end
      endcase
      // Source 3 (UART)
      case (scfg_3)
        2'd0:    pnd_3 <= 1'b0;
        2'd1:    pnd_3 <= i_irq_uart;
        default: begin
                   if (edge_3) pnd_3 <= 1'b1;
                 end
      endcase

      // ---- Claim: mark the winning source in-service and clear its edge
      // pending (registered claim event from the read channel) ----
      if (claim_evt) begin
        case (claim_src)
          2'd1: begin isv_1 <= 1'b1; if (scfg_1 == 2'd2) pnd_1 <= 1'b0; end
          2'd2: begin isv_2 <= 1'b1; if (scfg_2 == 2'd2) pnd_2 <= 1'b0; end
          2'd3: begin isv_3 <= 1'b1; if (scfg_3 == 2'd2) pnd_3 <= 1'b0; end
          default: ;
        endcase
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
      claim_evt <= 1'b0;
      claim_src <= 2'd0;
    end else begin
      s_axi_arready <= 1'b0;
      claim_evt <= 1'b0;

      if (s_axi_rvalid && s_axi_rready)
        s_axi_rvalid <= 1'b0;

      if (s_axi_arvalid && !s_axi_rvalid) begin
        s_axi_arready <= 1'b1;
        s_axi_rvalid  <= 1'b1;
        s_axi_rresp   <= 2'b00;
        case (s_axi_araddr[7:0])
          8'h00: s_axi_rdata <= {28'd0, prio_1};
          8'h04: s_axi_rdata <= {28'd0, prio_2};
          8'h08: s_axi_rdata <= {28'd0, prio_3};
          8'h0C: s_axi_rdata <= {28'd0, en_3, en_2, en_1};
          8'h10: s_axi_rdata <= {28'd0, threshold};
          8'h14: begin
                   s_axi_rdata <= {28'd0, (sel_high == 2'd0) ? 2'd0 : sel_high};
                   // Register the claim event: pulses one cycle after accept,
                   // carrying the winning source index.
                   claim_evt <= (sel_high != 2'd0);
                   claim_src <= sel_high;
                 end
          8'h18: s_axi_rdata <= {30'd0, scfg_1};
          8'h1C: s_axi_rdata <= {30'd0, scfg_2};
          8'h20: s_axi_rdata <= {30'd0, scfg_3};
          default: s_axi_rdata <= 32'd0;
        endcase
      end
    end
  end

endmodule
