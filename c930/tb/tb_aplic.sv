// =============================================================================
// tb_aplic.sv — Standalone unit test for c930_aplic
//
// Covers, via a small AXI4-Lite driver:
//   1. Reset: no IRQ
//   2. Priority arbitration: two pending edge sources -> claim returns the
//      higher-priority one; second claim returns the other (tie -> low index)
//   3. Claim de-asserts o_irq (edge pending cleared); complete keeps it off
//      until a NEW edge arrives
//   4. Threshold: source at/below threshold never raises o_irq
//   5. Enable mask + sourcecfg=0: disabled sources never capture
//   6. Level source (UART): tracks the line; claim masks via in-service;
//      complete re-arms (re-asserts while line still high); dropping the line
//      clears it
//   7. Claim with nothing pending returns 0 and does not hang
// =============================================================================
`timescale 1ns/1ps

module tb_aplic;
  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;

  logic irq_npu0, irq_npu1, irq_uart;
  logic o_irq;

  // AXI4-Lite slave side
  logic [31:0] awaddr, wdata;  logic [3:0] wstrb;
  logic awvalid, wvalid, awready, wready;
  logic bvalid, bready;  logic [1:0] bresp;
  logic [31:0] araddr;   logic arvalid, arready;
  logic [31:0] rdata;    logic rvalid, rready;  logic [1:0] rresp;

  c930_aplic dut (
    .i_clk          (clk),
    .i_rst_n        (rst_n),
    .i_irq_npu0     (irq_npu0),
    .i_irq_npu1     (irq_npu1),
    .i_irq_uart     (irq_uart),
    .o_irq          (o_irq),
    .s_axi_awaddr   (awaddr),
    .s_axi_awvalid  (awvalid),
    .s_axi_awready  (awready),
    .s_axi_wdata    (wdata),
    .s_axi_wstrb    (wstrb),
    .s_axi_wvalid   (wvalid),
    .s_axi_wready   (wready),
    .s_axi_bresp    (bresp),
    .s_axi_bvalid   (bvalid),
    .s_axi_bready   (bready),
    .s_axi_araddr   (araddr),
    .s_axi_arvalid  (arvalid),
    .s_axi_arready  (arready),
    .s_axi_rdata    (rdata),
    .s_axi_rresp    (rresp),
    .s_axi_rvalid   (rvalid),
    .s_axi_rready   (rready)
  );

  int errs = 0;

  // ---------------------------------------------------------------------------
  // AXI4-Lite driver tasks (mirror the MMIO bridge's single-cycle AW+W model)
  // ---------------------------------------------------------------------------
  task automatic axi_write(input [31:0] addr, input [31:0] data);
    begin
      @(posedge clk);
      awaddr = addr; wdata = data; wstrb = 4'hF;
      awvalid = 1'b1; wvalid = 1'b1;
      // Hold until both channels accepted
      do @(posedge clk); while (!(awready && wready));
      awvalid = 1'b0; wvalid = 1'b0;
      // Wait for the response, then consume it for one cycle
      do @(posedge clk); while (!bvalid);
      bready = 1'b1;
      @(posedge clk);
      bready = 1'b0;
    end
  endtask

  task automatic axi_read(input [31:0] addr, output logic [31:0] data);
    begin
      @(posedge clk);
      araddr = addr; arvalid = 1'b1;
      do @(posedge clk); while (!arready);
      arvalid = 1'b0;
      // rvalid asserts on the SAME edge as arready; sample it next edge,
      // then assert rready only after it is already high.
      do @(posedge clk); while (!rvalid);
      data = rdata;
      rready = 1'b1;
      @(posedge clk);
      rready = 1'b0;
    end
  endtask

  // ---------------------------------------------------------------------------
  // Checks
  // ---------------------------------------------------------------------------
  task automatic check(input string what, input logic got, input logic want);
    begin
      if (got !== want) begin
        $display("  [FAIL] %s: got %0d, want %0d", what, got, want);
        errs = errs + 1;
      end else begin
        $display("  [PASS] %s", what);
      end
    end
  endtask

  task automatic check_val(input string what, input int got, input int want);
    begin
      if (got !== want) begin
        $display("  [FAIL] %s: got %0d, want %0d", what, got, want);
        errs = errs + 1;
      end else begin
        $display("  [PASS] %s", what);
      end
    end
  endtask

  // Fire a 1-cycle pulse on an edge source. Drive inputs #1 after the edge
  // (after the DUT has sampled) so there is no set/sample race at posedge.
  task automatic pulse_npu0();
    begin
      @(posedge clk); #1 irq_npu0 = 1'b1;
      @(posedge clk); #1 irq_npu0 = 1'b0;
    end
  endtask
  task automatic pulse_npu1();
    begin
      @(posedge clk); #1 irq_npu1 = 1'b1;
      @(posedge clk); #1 irq_npu1 = 1'b0;
    end
  endtask

  // ---------------------------------------------------------------------------
  initial begin
    logic [31:0] r;
    awaddr = 0; wdata = 0; wstrb = 0; awvalid = 0; wvalid = 0; bready = 0;
    araddr = 0; arvalid = 0; rready = 0;
    irq_npu0 = 0; irq_npu1 = 0; irq_uart = 0;

    repeat (5) @(posedge clk);
    rst_n = 1;
    repeat (5) @(posedge clk);

    $display("=== APLIC unit test ===");

    // 1. Reset: nothing pending, no IRQ, claim returns 0
    check("reset: o_irq low", o_irq, 1'b0);
    axi_read(32'h4000_4014, r);
    check_val("claim with nothing pending returns 0", r[2:0], 0);

    // 2. Configure: NPU0=prio3(edge), NPU1=prio2(edge), UART=prio1(level)
    axi_write(32'h4000_4000, 32'd3);   // prio1
    axi_write(32'h4000_4004, 32'd2);   // prio2
    axi_write(32'h4000_4008, 32'd1);   // prio3
    axi_write(32'h4000_400C, 32'h0E);  // enable 1,2,3
    axi_write(32'h4000_4010, 32'd0);   // threshold 0
    axi_write(32'h4000_4018, 32'd2);   // src1 edge
    axi_write(32'h4000_401C, 32'd2);   // src2 edge
    axi_write(32'h4000_4020, 32'd1);   // src3 level

    // 3. Single edge: NPU1 fires -> o_irq, claim returns 2
    pulse_npu1();
    repeat (2) @(posedge clk);
    check("NPU1 edge: o_irq high", o_irq, 1'b1);
    axi_read(32'h4000_4014, r);
    check_val("claim returns NPU1 (2)", r[2:0], 2);
    repeat (2) @(posedge clk);
    check("after claim: o_irq low (edge pending cleared)", o_irq, 1'b0);
    axi_write(32'h4000_4014, 32'd2);   // complete source 2
    repeat (2) @(posedge clk);
    check("after complete: still low (no new edge)", o_irq, 1'b0);

    // 4. Arbitration: NPU1 (prio 2) pending, then NPU0 (prio 3) fires.
    //    First claim must return NPU0 (higher priority).
    pulse_npu1();
    repeat (2) @(posedge clk);
    pulse_npu0();
    repeat (2) @(posedge clk);
    check("two pending: o_irq high", o_irq, 1'b1);
    axi_read(32'h4000_4014, r);
    check_val("arbitration: higher-prio NPU0 (1) claimed first", r[2:0], 1);
    axi_write(32'h4000_4014, 32'd1);
    repeat (2) @(posedge clk);
    check("after NPU0 claim+complete: NPU1 still pending", o_irq, 1'b1);
    axi_read(32'h4000_4014, r);
    check_val("second claim returns NPU1 (2)", r[2:0], 2);
    axi_write(32'h4000_4014, 32'd2);
    repeat (2) @(posedge clk);
    check("all claimed+completed: o_irq low", o_irq, 1'b0);

    // 5. Threshold: set 2 -> NPU1 (prio 2) must NOT interrupt; NPU0 (3) may.
    //    NOTE: edge pending still latches below threshold (APLIC semantics);
    //    it is delivered once the threshold drops again.
    axi_write(32'h4000_4010, 32'd2);
    pulse_npu1();
    repeat (2) @(posedge clk);
    check("threshold: NPU1 prio==threshold does not interrupt", o_irq, 1'b0);
    axi_read(32'h4000_4014, r);
    check_val("threshold: claim returns 0", r[2:0], 0);
    pulse_npu0();
    repeat (2) @(posedge clk);
    check("threshold: NPU0 above threshold still interrupts", o_irq, 1'b1);
    axi_read(32'h4000_4014, r);
    check_val("threshold claim returns NPU0 (1)", r[2:0], 1);
    axi_write(32'h4000_4014, 32'd1);
    axi_write(32'h4000_4010, 32'd0);   // restore threshold 0
    // NPU1's below-threshold pending is now deliverable -> drain it
    repeat (2) @(posedge clk);
    check("below-threshold pending delivered after threshold drop", o_irq, 1'b1);
    axi_read(32'h4000_4014, r);
    check_val("drain claim returns NPU1 (2)", r[2:0], 2);
    axi_write(32'h4000_4014, 32'd2);
    repeat (2) @(posedge clk);
    check("drained: o_irq low", o_irq, 1'b0);

    // 6. sourcecfg=0 disables capture; enable mask gates delivery but not the
    //    edge latch (pending accumulates while masked, per APLIC semantics).
    axi_write(32'h4000_4018, 32'd0);   // disable src1
    pulse_npu0();
    repeat (2) @(posedge clk);
    check("disabled sourcecfg: no interrupt", o_irq, 1'b0);
    axi_read(32'h4000_4014, r);
    check_val("disabled source: claim returns 0", r[2:0], 0);
    axi_write(32'h4000_4018, 32'd2);   // re-enable src1 edge
    axi_write(32'h4000_400C, 32'h04);  // enable only src3
    pulse_npu0();
    repeat (2) @(posedge clk);
    check("enable mask: edge not delivered while masked", o_irq, 1'b0);
    axi_write(32'h4000_400C, 32'h0E);  // re-enable all
    repeat (2) @(posedge clk);
    // The masked NPU0 edge was latched; delivery resumes now -> drain it.
    check("latched edge delivered after unmask", o_irq, 1'b1);
    axi_read(32'h4000_4014, r);
    check_val("unmask drain claim returns NPU0 (1)", r[2:0], 1);
    axi_write(32'h4000_4014, 32'd1);
    repeat (2) @(posedge clk);
    check("drained: o_irq low", o_irq, 1'b0);

    // 7. Level source (UART): claim sets in-service, level stays, o_irq drops;
    //    complete re-arms -> re-asserts while line still high; line-drop stops.
    @(posedge clk); #1 irq_uart = 1;
    repeat (2) @(posedge clk);
    check("UART level high: o_irq high", o_irq, 1'b1);
    axi_read(32'h4000_4014, r);
    check_val("claim returns UART (3)", r[2:0], 3);
    repeat (2) @(posedge clk);
    check("level claimed: o_irq low (in-service)", o_irq, 1'b0);
    axi_write(32'h4000_4014, 32'd3);   // complete
    repeat (2) @(posedge clk);
    check("level complete while line high: re-asserts", o_irq, 1'b1);
    // ISR clears the source (drops the line) -> pending clears
    @(posedge clk); #1 irq_uart = 0;
    repeat (2) @(posedge clk);
    check("level line dropped: o_irq low", o_irq, 1'b0);

    // 8. New edge after complete re-fires (registers still configured)
    pulse_npu0();
    repeat (2) @(posedge clk);
    check("new NPU0 edge re-fires", o_irq, 1'b1);
    axi_read(32'h4000_4014, r);
    check_val("final claim NPU0 (1)", r[2:0], 1);
    axi_write(32'h4000_4014, 32'd1);
    repeat (2) @(posedge clk);
    check("final complete: o_irq low", o_irq, 1'b0);

    repeat (5) @(posedge clk);
    if (errs == 0)
      $display("\n  APLIC UNIT TEST PASSED\n");
    else
      $display("\n  APLIC UNIT TEST FAILED: %0d errors\n", errs);
    $finish;
  end

endmodule
