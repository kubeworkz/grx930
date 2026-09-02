// Minimal testbench: program NPU via AXI-Lite, verify command queue dispatch
module tb_csr_queue;
  logic clk = 0;
  logic rst_n = 0;

  always #5 clk = ~clk;

  // AXI-Lite signals
  logic [31:0] awaddr, araddr, wdata, rdata;
  logic awvalid, awready, wvalid, wready, bvalid, bready;
  logic arvalid, arready, rvalid, rready;
  logic [1:0] bresp, rresp;
  logic [3:0] wstrb;

  logic o_start, i_busy, i_done, i_error;
  logic [15:0] o_dim_m, o_dim_n, o_dim_k;
  logic [31:0] o_a_base, o_b_base, o_c_base;
  logic [2:0] o_precision;

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
    .i_busy(i_busy), .i_done(i_done), .i_error(i_error),
    .i_cycle_count(0), .i_op_count(0), .i_stall_count(0), .i_dma_cycle_count(0)
  );

  // Simulate DMA: assert busy after start, deassert after 10 cycles
  logic [3:0] dma_cnt;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dma_cnt <= 0;
      i_busy <= 0;
      i_done <= 0;
    end else begin
      i_done <= 0;
      if (o_start) begin
        i_busy <= 1;
        dma_cnt <= 10;
      end else if (i_busy && dma_cnt > 0) begin
        dma_cnt <= dma_cnt - 1;
        if (dma_cnt == 1) begin
          i_busy <= 0;
          i_done <= 1;
        end
      end
    end
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

  int pass_cnt = 0;
  int fail_cnt = 0;
  logic [31:0] rdata_var;

  initial begin
    rst_n = 0;
    awvalid = 0; wvalid = 0; arvalid = 0; rready = 0; bready = 1;
    wstrb = 4'hF;
    repeat(5) @(posedge clk);
    rst_n = 1;
    repeat(5) @(posedge clk);

    // Test 1: Single GEMM dispatch (idle path, no FIFO)
    $display("[TEST 1] Single GEMM dispatch (idle path)");
    axi_write(32'h08, 4);   // DIM_M = 4
    axi_write(32'h0C, 8);   // DIM_N = 8
    axi_write(32'h10, 16);  // DIM_K = 16
    axi_write(32'h14, 32'h1000); // A_BASE
    axi_write(32'h18, 32'h2000); // B_BASE
    axi_write(32'h1C, 32'h3000); // C_BASE
    axi_write(32'h20, 0);   // PREC = INT8
    axi_write(32'h00, 1);   // CTRL.START

    // Wait for DMA to complete
    wait(i_done);
    @(posedge clk);
    axi_read(32'h04, rdata_var);
    $display("  STATUS = %h (expect bit1=1 DONE)", rdata_var);
    if (rdata_var[1]) begin pass_cnt++; $display("  [PASS]"); end
    else begin fail_cnt++; $display("  [FAIL]"); end

    // Test 2: Back-to-back START (busy path, queued)
    $display("\n[TEST 2] Back-to-back START (queued)");
    axi_write(32'h08, 2);   // DIM_M = 2
    axi_write(32'h0C, 4);   // DIM_N = 4
    axi_write(32'h10, 8);   // DIM_K = 8
    axi_write(32'h00, 1);   // CTRL.START (engine is idle, should dispatch immediately)

    // Immediately write another GEMM while first is running
    axi_write(32'h08, 1);   // DIM_M = 1
    axi_write(32'h0C, 1);   // DIM_N = 1
    axi_write(32'h10, 1);   // DIM_K = 1
    axi_write(32'h00, 1);   // CTRL.START (engine busy, should queue)

    // Wait for both to complete
    wait(i_done); @(posedge clk);  // first done
    wait(i_done); @(posedge clk);  // second done

    axi_read(32'h04, rdata_var);
    $display("  STATUS = %h", rdata_var);
    if (rdata_var[1]) begin pass_cnt++; $display("  [PASS]"); end
    else begin fail_cnt++; $display("  [FAIL]"); end

    // Test 3: QUEUE_STAT after both complete
    $display("\n[TEST 3] QUEUE_STAT register");
    axi_read(32'h38, rdata_var);
    $display("  QUEUE_STAT = %h (occupancy=%0d, full=%0d)", rdata_var, rdata_var[3:0], rdata_var[4]);
    if (rdata_var[3:0] == 0) begin pass_cnt++; $display("  [PASS]"); end
    else begin fail_cnt++; $display("  [FAIL]"); end

    $display("\n=== RESULTS: %0d PASSED, %0d FAILED ===", pass_cnt, fail_cnt);
    $finish;
  end

  // Timeout
  initial begin
    #100000;
    $display("[TIMEOUT]");
    $finish;
  end
endmodule
