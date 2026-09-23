// -----------------------------------------------------------------------------
// tb_npu_cal_queue.sv
//
// C3(b)'s named regression: a START that arrives while the PTA tile is
// calibrating (grxcp docs/designs/pta_cpu_integration.md section 3.2, and the
// calibration document's section 6).  The command must queue -- never dispatch
// into a tile that is unavailable, and never be dropped -- so that the
// completion predicate the CSR's header documents, occupancy == 0 and
// STATUS.BUSY == 0, keeps telling the truth.
//
// Three STARTs back to back with the queue's occupancy checked at each step, as
// the calibration document asks for, plus the two things that must not happen:
// o_start must never pulse while i_cal_busy is set, and the predicate must never
// read "finished" with work outstanding.
//
// The ablation is the guard itself: build with -DCAL_GUARD_ABLATE and
// c930_npu_csr drops calibration from its dispatch condition.  Then the first
// START dispatches straight into the calibrating tile and this bench fails,
// which is the point of it.
//
//   iverilog -g2012 -o cal_queue.vvp rtl/c930_npu_csr.sv tb/tb_npu_cal_queue.sv
//   vvp cal_queue.vvp
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_npu_cal_queue;
  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;

  logic [31:0] awaddr, araddr, wdata, rdata;
  logic awvalid, awready, wvalid, wready, bvalid, bready;
  logic arvalid, arready, rvalid, rready;
  logic [1:0] bresp, rresp;
  logic [3:0] wstrb;

  logic        o_start, i_busy, i_done, i_error;
  logic        cal_busy;
  logic [15:0] o_dim_m, o_dim_n, o_dim_k;
  logic [31:0] o_a_base, o_b_base, o_c_base;
  logic [2:0]  o_precision;
  logic        f_valid;
  logic [15:0] f_m, f_n, f_k;
  logic [31:0] f_a, f_b, f_c;
  logic [2:0]  f_prec;

  c930_npu_csr #(.CMD_QUEUE_DEPTH(4)) u_csr (
    .i_clk(clk), .i_rst_n(rst_n),
    .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
    .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid),
    .s_axi_wready(wready), .s_axi_bresp(bresp), .s_axi_bvalid(bvalid),
    .s_axi_bready(bready),
    .s_axi_araddr(araddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
    .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid),
    .s_axi_rready(rready),
    .o_start(o_start), .o_dim_m(o_dim_m), .o_dim_n(o_dim_n),
    .o_dim_k(o_dim_k), .o_a_base(o_a_base), .o_b_base(o_b_base),
    .o_c_base(o_c_base), .o_precision(o_precision),
    .i_busy(i_busy), .i_cal_busy(cal_busy), .i_done(i_done), .i_error(i_error),
    .i_cycle_count(0), .i_op_count(0), .i_stall_count(0), .i_dma_cycle_count(0),
    .o_fifo_valid(f_valid), .o_fifo_dim_m(f_m), .o_fifo_dim_n(f_n), .o_fifo_dim_k(f_k),
    .o_fifo_a_base(f_a), .o_fifo_b_base(f_b), .o_fifo_c_base(f_c),
    .o_fifo_precision(f_prec)
  );

  // The DMA, as tb_csr_queue models it: busy one cycle after the start pulse,
  // which is the timing that makes the queue's edge cases real.
  logic [3:0] dma_cnt;
  logic       dma_pending;
  int         dispatched;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dma_cnt <= 0; i_busy <= 0; i_done <= 0; dma_pending <= 0; dispatched <= 0;
    end else begin
      i_done      <= 0;
      dma_pending <= 0;
      if (o_start) begin
        dma_pending <= 1;
        dispatched  <= dispatched + 1;
      end else if (dma_pending && !i_busy) begin
        i_busy <= 1; dma_cnt <= 10; dma_pending <= 0;
      end else if (i_busy && dma_cnt > 0) begin
        dma_cnt <= dma_cnt - 1;
        if (dma_cnt == 1) begin i_busy <= 0; i_done <= 1; end
      end
    end
  end

  assign i_error = 1'b0;

  // The thing that must not happen, watched for the whole run.
  int violations;
  always @(posedge clk)                 // a monitor, not logic: it reports
    if (rst_n && o_start && cal_busy) begin
      violations <= violations + 1;
      $display("  [FAIL] o_start pulsed while CAL_BUSY was set");
    end

  task axi_write(input [31:0] addr, input [31:0] data);
    @(posedge clk);
    awaddr <= addr; wdata <= data; wstrb <= 4'hF;
    awvalid <= 1; wvalid <= 1;
    wait(awready && wready);
    @(posedge clk);
    awvalid <= 0; wvalid <= 0;
    wait(!bvalid || bready);
    @(posedge clk);
  endtask

  task axi_read(input [31:0] addr, output [31:0] data);
    @(posedge clk);
    araddr <= addr; arvalid <= 1;
    wait(arready);
    @(posedge clk);
    arvalid <= 0;
    wait(rvalid);
    data = rdata;
    rready <= 1;
    @(posedge clk);
    rready <= 0;
  endtask

  int pass_cnt = 0, fail_cnt = 0;
  logic [31:0] rd, occ, st;

  task check(input string what, input logic ok);
    if (ok) begin pass_cnt++; $display("  [PASS] %s", what); end
    else    begin fail_cnt++; $display("  [FAIL] %s", what); end
  endtask

  task submit;                      // one command, parameters and START
    axi_write(32'h08, 4);
    axi_write(32'h0C, 4);
    axi_write(32'h10, 4);
    axi_write(32'h00, 1);
  endtask

  initial begin
    violations = 0;
    awvalid = 0; wvalid = 0; arvalid = 0; rready = 0; bready = 1; wstrb = 4'hF;
    cal_busy = 0;
    repeat (5) @(posedge clk);
    rst_n = 1;
    repeat (5) @(posedge clk);

    // ---- A GEMM with no calibration in the way, so the bench itself is sound.
    $display("[CQ1] a command with the tile free");
    submit();
    wait (i_done); @(posedge clk);
    axi_read(32'h38, rd);
    check("dispatched and the queue drained", rd[3:0] == 0 && dispatched == 1);

    // ---- The regression: three STARTs during a calibration.
    $display("[CQ2] three commands while CAL_BUSY is set");
    cal_busy = 1;
    repeat (2) @(posedge clk);
    for (int i = 1; i <= 3; i++) begin
      submit();
      axi_read(32'h38, occ);
      axi_read(32'h04, st);
      $display("  after START %0d: occupancy %0d, full %0d, STATUS.BUSY %0d",
               i, occ[3:0], occ[4], st[0]);
      check($sformatf("occupancy is %0d", i), occ[3:0] == i[3:0]);
      // The predicate the CSR's header documents must say "not finished".
      check("occupancy == 0 && busy == 0 is false", !(occ[3:0] == 0 && st[0] == 0));
    end
    check("nothing dispatched into the calibration", dispatched == 1);

    // ---- And when the tile comes back, every queued command runs.
    $display("[CQ3] the tile comes back");
    cal_busy = 0;
    repeat (3) begin
      wait (i_done); @(posedge clk);
    end
    repeat (20) @(posedge clk);
    axi_read(32'h38, rd);
    check("all three dispatched", dispatched == 4);
    check("the queue drained", rd[3:0] == 0);
    axi_read(32'h04, st);
    check("and now the predicate says finished", st[0] == 0 && rd[3:0] == 0);

    // ---- A calibration that starts while a command is in flight changes
    // ---- nothing: BUSY already holds the dispatcher off.
    $display("[CQ4] a calibration on top of a running command");
    submit();
    @(posedge clk);
    cal_busy = 1;
    submit();
    axi_read(32'h38, rd);
    check("the second command queued", rd[3:0] == 1);
    cal_busy = 0;
    repeat (2) begin
      wait (i_done); @(posedge clk);
    end
    repeat (20) @(posedge clk);
    axi_read(32'h38, rd);
    check("both ran", dispatched == 6 && rd[3:0] == 0);

    check("no dispatch ever reached a calibrating tile", violations == 0);
    $display("=== tb_npu_cal_queue: %0d PASSED, %0d FAILED ===", pass_cnt, fail_cnt);
    if (fail_cnt != 0) $fatal(1, "cal_busy dispatch guard: %0d checks failed", fail_cnt);
    $finish;
  end

  initial begin
    #200000;
    $fatal(1, "[TIMEOUT] tb_npu_cal_queue");
  end
endmodule
