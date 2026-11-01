// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Gridworkz
// -----------------------------------------------------------------------------
// tb_npu_refused_dispatch.sv
//
// Two things c930_npu_csr must get right about its command queue:
//
// 1. A refused command must not wedge the dispatcher.  The DMA checks the
//    dimensions when it takes START; past the limits it raises ERROR and stays
//    in P_IDLE, so BUSY never rises.  The dispatcher used to wait in D_WAIT for
//    that BUSY forever and take no further command until reset.  Here a START
//    with K past MAX_K is followed by good commands, which must run.
//
// 2. QUEUE_STAT reads as c930_npu_driver.h documents it at the SoC's depth
//    of 4: occupancy in [3:0], full in bit 4.  The register used to pack the
//    count at its own width, which put full in bit 3 at depth 4, so the
//    driver's full check (bit 4) never fired and a full queue read as 0x0C.
//
// The DMA here answers start the way c930_npu_dma.sv does from P_IDLE: at the
// edge it sees the pulse it either leaves P_IDLE (BUSY) and clears ERROR, or,
// for dimensions past the limits, sets ERROR and stays idle.
//
//   iverilog -g2012 -o refused.vvp rtl/c930_npu_csr.sv tb/tb_npu_refused_dispatch.sv
//   vvp refused.vvp
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_npu_refused_dispatch;
  localparam int MAX_M = 8, MAX_N = 12, MAX_K = 16;

  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;

  logic [31:0] awaddr, araddr, wdata, rdata;
  logic awvalid, awready, wvalid, wready, bvalid, bready;
  logic arvalid, arready, rvalid, rready;
  logic [1:0] bresp, rresp;
  logic [3:0] wstrb;

  logic        o_start, i_busy, i_done, i_error;
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
    .i_busy(i_busy), .i_cal_busy(1'b0), .i_done(i_done), .i_error(i_error),
    .i_cycle_count(0), .i_op_count(0), .i_stall_count(0), .i_dma_cycle_count(0),
    .o_fifo_valid(f_valid), .o_fifo_dim_m(f_m), .o_fifo_dim_n(f_n), .o_fifo_dim_k(f_k),
    .o_fifo_a_base(f_a), .o_fifo_b_base(f_b), .o_fifo_c_base(f_c),
    .o_fifo_precision(f_prec)
  );

  // The DMA's answer to start, from P_IDLE, as c930_npu_dma.sv gives it.
  int dma_len = 12;                  // cycles a GEMM keeps BUSY
  int dma_cnt;
  int dispatched, refused, completed;
  wire dims_ok = o_dim_m >= 1 && o_dim_m <= MAX_M && o_dim_n >= 1 && o_dim_n <= MAX_N &&
                 o_dim_k >= 1 && o_dim_k <= MAX_K;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      i_busy <= 0; i_done <= 0; i_error <= 0; dma_cnt <= 0;
      dispatched <= 0; refused <= 0; completed <= 0;
    end else begin
      i_done <= 0;
      if (o_start && !i_busy) begin
        if (!dims_ok) begin
          i_error <= 1; refused <= refused + 1;
        end else begin
          i_error <= 0; i_busy <= 1; dma_cnt <= dma_len; dispatched <= dispatched + 1;
        end
      end else if (i_busy) begin
        if (dma_cnt == 1) begin i_busy <= 0; i_done <= 1; completed <= completed + 1; end
        dma_cnt <= dma_cnt - 1;
      end
    end
  end

  // A start the DMA cannot take is a dispatcher bug in its own right.
  int lost_starts;
  always @(posedge clk)
    if (rst_n && o_start && i_busy) begin
      lost_starts <= lost_starts + 1;
      $display("  [FAIL] o_start pulsed while the DMA was busy");
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
  logic [31:0] rd, st;

  task check(input string what, input logic ok);
    if (ok) begin pass_cnt++; $display("  [PASS] %s", what); end
    else    begin fail_cnt++; $display("  [FAIL] %s", what); end
  endtask

  task dims(input int m, input int n, input int k);
    axi_write(32'h08, m); axi_write(32'h0C, n); axi_write(32'h10, k);
  endtask

  // Idle and drained, or give up: the wedge this bench is about never drains.
  task settle(output logic ok);
    ok = 0;
    for (int i = 0; i < 400 && !ok; i++) begin
      repeat (4) @(posedge clk);
      axi_read(32'h38, rd);
      axi_read(32'h04, st);
      if (rd[3:0] == 0 && st[0] == 0) ok = 1;
    end
  endtask

  logic ok;
  int d0, r0;

  initial begin
    lost_starts = 0;
    awvalid = 0; wvalid = 0; arvalid = 0; rready = 0; bready = 1; wstrb = 4'hF;
    repeat (5) @(posedge clk);
    rst_n = 1;
    repeat (5) @(posedge clk);

    $display("[RD1] a good command, so the bench itself is sound");
    dims(4, 4, 4); axi_write(32'h00, 1);
    settle(ok);
    axi_read(32'h04, st);
    check("it ran and the queue drained", ok && dispatched == 1 && completed == 1);
    check("STATUS: DONE set, ERROR clear", st[1] == 1 && st[2] == 0);

    $display("[RD2] K past MAX_K: refused with ERROR");
    dims(4, 4, 20); axi_write(32'h00, 1);
    repeat (10) @(posedge clk);
    axi_read(32'h04, st);
    check("the DMA refused it", refused == 1 && dispatched == 1);
    check("STATUS: ERROR set, BUSY clear", st[2] == 1 && st[0] == 0);

    $display("[RD3] a good command after the refused one runs");
    dims(4, 4, 4); axi_write(32'h00, 1);
    settle(ok);
    axi_read(32'h04, st);
    $display("  dispatched %0d, completed %0d, STATUS 0x%0h, QUEUE_STAT 0x%0h", dispatched, completed, st, rd);
    check("dispatched and completed", ok && dispatched == 2 && completed == 2);
    check("ERROR cleared by the good command", st[2] == 0 && st[1] == 1);

    $display("[RD4] refused, refused, then three good ones back to back");
    dims(8, 12, 17); axi_write(32'h00, 1); axi_write(32'h00, 1);
    repeat (10) @(posedge clk);
    check("both refused", refused == 3);
    dims(8, 12, 16);
    d0 = dispatched;
    repeat (3) axi_write(32'h00, 1);
    settle(ok);
    check("all three ran", ok && dispatched == d0 + 3 && completed == dispatched);

    $display("[RD5] QUEUE_STAT at depth 4: occupancy [3:0], full bit 4");
    axi_read(32'h3C, rd);
    check("QUEUE_MAX reads 4", rd == 4);
    dma_len = 400;                    // hold the engine so the queue fills
    dims(4, 4, 4);
    axi_write(32'h00, 1);             // dispatches straight away
    repeat (4) @(posedge clk);
    for (int i = 1; i <= 4; i++) begin
      axi_write(32'h00, 1);
      axi_read(32'h38, rd);
      $display("  after queued START %0d: QUEUE_STAT 0x%02h", i, rd);
      check($sformatf("occupancy %0d in [3:0], full (bit 4) %0d", i, i == 4),
            rd[3:0] == i[3:0] && rd[4] == (i == 4) && rd[31:5] == 0);
    end
    check("a full queue reads 0x14, as the driver header says", rd == 32'h14);
    d0 = dispatched;
    axi_write(32'h00, 1);             // the fifth: dropped
    axi_read(32'h38, rd);
    check("a START against a full queue changes nothing", rd == 32'h14);
    dma_len = 12;
    settle(ok);
    check("the four queued commands ran, the dropped one did not", ok && dispatched == d0 + 4);

    check("no start ever reached a busy DMA", lost_starts == 0);
    $display("=== tb_npu_refused_dispatch: %0d PASSED, %0d FAILED ===", pass_cnt, fail_cnt);
    if (fail_cnt != 0) $fatal(1, "refused dispatch / QUEUE_STAT: %0d checks failed", fail_cnt);
    $finish;
  end

  initial begin
    #3000000;
    $fatal(1, "[TIMEOUT] tb_npu_refused_dispatch");
  end
endmodule
