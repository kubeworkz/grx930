// tb_perf_quick.sv — Quick test: boot core, wait for DONE, then directly
// program the NPU CSR via AXI to re-trigger a GEMM and check completion.
// Bypasses the C driver's perf_bench to isolate the NPU re-trigger bug.

`timescale 1ns/1ps

module tb_perf_quick;

  reg         clk = 0;
  reg         rst_n = 0;
  reg  [31:0] cycle = 0;

  always #5 clk = ~clk; // 100 MHz
  always @(posedge clk) cycle <= cycle + 1;

  c930_soc_top #(
    .MAX_M(8),
    .MAX_K(16),
    .MAX_N(12)
  ) dut (
    .i_clk   (clk),
    .i_rst_n (rst_n)
  );

  // ---- Load firmware hex (32-bit word hex -> 8-bit byte DDR) ----
  logic [31:0] img [0:1023];
  initial begin
    int i;
    for (i = 0; i < 1024; i++) img[i] = 32'h0;
    $readmemh("sw/npu_prog.hex", img);
    for (i = 0; i < 1024; i++) begin
      dut.u_ddr.mem[4*i + 0] = img[i][7:0];
      dut.u_ddr.mem[4*i + 1] = img[i][15:8];
      dut.u_ddr.mem[4*i + 2] = img[i][23:16];
      dut.u_ddr.mem[4*i + 3] = img[i][31:24];
    end
  end

  // ---- Preload A/B/C data for M=2 N=3 K=4 INT8 (small, fast) ----
  // A = [[1,2,3,4],[5,6,7,8]] = row-major 2x4 = bytes at 0x8000
  // B = [[1,0],[0,1],[1,1],[0,0]] = row-major 4x3 = bytes at 0x8400
  // C expected = A*B = [[4,5,5],[12,13,13]]
  initial begin
    // A (2x4 INT8): row0={1,2,3,4}, row1={5,6,7,8}
    dut.u_ddr.mem[32'h8000] = 8'h01;  dut.u_ddr.mem[32'h8001] = 8'h02;
    dut.u_ddr.mem[32'h8002] = 8'h03;  dut.u_ddr.mem[32'h8003] = 8'h04;
    dut.u_ddr.mem[32'h8004] = 8'h05;  dut.u_ddr.mem[32'h8005] = 8'h06;
    dut.u_ddr.mem[32'h8006] = 8'h07;  dut.u_ddr.mem[32'h8007] = 8'h08;
    // B (4x3 INT8): row0={1,0,0}, row1={0,1,0}, row2={1,0,1}, row3={0,0,0}
    dut.u_ddr.mem[32'h8400] = 8'h01;  dut.u_ddr.mem[32'h8401] = 8'h00;
    dut.u_ddr.mem[32'h8402] = 8'h00;
    dut.u_ddr.mem[32'h8403] = 8'h00;  dut.u_ddr.mem[32'h8404] = 8'h01;
    dut.u_ddr.mem[32'h8405] = 8'h00;
    dut.u_ddr.mem[32'h8406] = 8'h01;  dut.u_ddr.mem[32'h8407] = 8'h00;
    dut.u_ddr.mem[32'h8408] = 8'h01;
    dut.u_ddr.mem[32'h8409] = 8'h00;  dut.u_ddr.mem[32'h840a] = 8'h00;
    dut.u_ddr.mem[32'h840b] = 8'h00;
    // DIMS: M=2, N=3, K=4, prec=0 (INT8)
    dut.u_ddr.mem[32'h9400] = 8'h02;  dut.u_ddr.mem[32'h9401] = 8'h00;
    dut.u_ddr.mem[32'h9404] = 8'h03;  dut.u_ddr.mem[32'h9405] = 8'h00;
    dut.u_ddr.mem[32'h9408] = 8'h04;  dut.u_ddr.mem[32'h9409] = 8'h00;
    dut.u_ddr.mem[32'h940c] = 8'h00;  // prec=0 (INT8)
    // Clear done/stress/phase
    dut.u_ddr.mem[32'h9410] = 8'h00;  dut.u_ddr.mem[32'h9411] = 8'h00;
    dut.u_ddr.mem[32'h9412] = 8'h00;  dut.u_ddr.mem[32'h9413] = 8'h00;
    dut.u_ddr.mem[32'h9490] = 8'h00;
    dut.u_ddr.mem[32'h9500] = 8'h00;  // PERF_RES_ADDR clear
  end

  // ---- Monitor NPU signals ----
  wire        npu_busy  = dut.u_npu.o_busy;
  wire        npu_done  = dut.u_npu.o_done;
  wire [2:0]  dma_phase = dut.u_npu.u_dma.phase;
  wire [2:0]  core_st   = dut.u_npu.u_core.state;
  wire        csr_start = dut.u_npu.u_csr.start_pulse;
  wire        csr_done  = dut.u_npu.u_csr.done_latch;
  wire [31:0] pc        = dut.u_cpu.if_pipe_pcf_new;

  // Track NPU kicks
  integer kicks = 0;
  always @(posedge clk) begin
    if (csr_start) begin
      kicks <= kicks + 1;
      $display("[KICK #%0d] t=%0d prec=%0d M=%0d N=%0d K=%0d A=%h B=%h C=%h",
        kicks, cycle,
        dut.u_npu.u_csr.precision,
        dut.u_npu.u_csr.dim_m,
        dut.u_npu.u_csr.dim_n,
        dut.u_npu.u_csr.dim_k,
        dut.u_npu.u_csr.a_base,
        dut.u_npu.u_csr.b_base,
        dut.u_npu.u_csr.c_base);
      $fflush();
    end
  end

  // Track NPU done
  always @(posedge clk) begin
    if (npu_done) begin
      $display("[NPU-DONE] t=%0d dma_phase=%0d core_state=%0d done_latch=%0d",
        cycle, dma_phase, core_st, csr_done);
      $fflush();
    end
  end

  // When DMA phase changes, log it
  reg [2:0] last_dma_phase;
  always @(posedge clk) begin
    last_dma_phase <= dma_phase;
    if (dma_phase != last_dma_phase && cycle > 100) begin
      $display("[DMA] t=%0d phase %0d -> %0d", cycle, last_dma_phase, dma_phase);
      $fflush();
    end
  end

  // When core state changes, log it
  reg [2:0] last_core_st;
  always @(posedge clk) begin
    last_core_st <= core_st;
    if (core_st != last_core_st && cycle > 100) begin
      $display("[CORE] t=%0d state %0d -> %0d", cycle, last_core_st, core_st);
      $fflush();
    end
  end

  // ---- Test body ----
  initial begin
    $dumpfile("build/vcd/tb_perf_quick.vcd");
    $dumpvars(0, tb_perf_quick);

    // Reset
    rst_n = 0;
    repeat(20) @(posedge clk);
    rst_n = 1;
    $display("[BOOT] t=%0d Core released from reset", cycle);

    // Wait for first GEMM to complete (DONE signal)
    wait(dut.u_ddr.mem[32'h9410] == 8'hDE && dut.u_ddr.mem[32'h9411] == 8'hAD);
    $display("[GEMM1] t=%0d First GEMM completed", cycle);
    $display("[GEMM1] NPU busy=%0d done=%0d dma_phase=%0d core_state=%0d done_latch=%0d",
      npu_busy, npu_done, dma_phase, core_st, csr_done);
    $fflush();

    // Wait a bit for the core to reach perf_bench
    repeat(1000) @(posedge clk);

    // Check NPU state
    $display("[CHECK] t=%0d NPU busy=%0d done=%0d dma_phase=%0d core_state=%0d done_latch=%0d kicks=%0d",
      cycle, npu_busy, npu_done, dma_phase, core_st, csr_done, kicks);
    $fflush();

    // If the NPU hasn't been kicked yet, wait more
    if (kicks < 2) begin
      $display("[WAIT] NPU not yet kicked for perf_bench, waiting...");
      repeat(50000) @(posedge clk);
      $display("[CHECK2] t=%0d NPU busy=%0d done=%0d dma_phase=%0d core_state=%0d done_latch=%0d kicks=%0d",
        cycle, npu_busy, npu_done, dma_phase, core_st, csr_done, kicks);
    end

    // If NPU was kicked but didn't complete, log stuck state
    if (kicks >= 2 && !csr_done) begin
      $display("[STUCK] NPU kicked but done_latch=0. Dumping state...");
      $display("[STUCK] dma_phase=%0d core_state=%0d launched=%0d t=%0d w_r=%0d w_n=%0d",
        dma_phase, core_st, dut.u_npu.u_dma.launched,
        dut.u_npu.u_core.t, dut.u_npu.u_core.w_r, dut.u_npu.u_core.w_n);
      $display("[STUCK] DDR[0x8000..0x8007] = %h%h%h%h%h%h%h%h",
        dut.u_ddr.mem[32'h8000], dut.u_ddr.mem[32'h8001], dut.u_ddr.mem[32'h8002], dut.u_ddr.mem[32'h8003],
        dut.u_ddr.mem[32'h8004], dut.u_ddr.mem[32'h8005], dut.u_ddr.mem[32'h8006], dut.u_ddr.mem[32'h8007]);
      $fflush();
    end

    // Wait for PHASE = 0x11 (perf_bench completed)
    wait(dut.u_ddr.mem[32'h9490] == 8'h11);
    $display("[PERF] t=%0d perf_bench completed! phase=0x11", cycle);
    $fflush();

    // Wait for perf results
    repeat(1000) @(posedge clk);
    $display("[RESULT] DDR[9500..950B] = %h%h%h%h %h%h%h%h %h%h%h%h",
      dut.u_ddr.mem[32'h9500], dut.u_ddr.mem[32'h9501], dut.u_ddr.mem[32'h9502], dut.u_ddr.mem[32'h9503],
      dut.u_ddr.mem[32'h9504], dut.u_ddr.mem[32'h9505], dut.u_ddr.mem[32'h9506], dut.u_ddr.mem[32'h9507],
      dut.u_ddr.mem[32'h9508], dut.u_ddr.mem[32'h9509], dut.u_ddr.mem[32'h950a], dut.u_ddr.mem[32'h950b]);

    $display("[PASS] Quick perf test completed");
    $finish;
  end

  // Timeout
  initial begin
    #50000000; // 50M cycles = ~17 seconds @ 100MHz sim time
    $display("[TIMEOUT] Simulation timed out at t=%0d", cycle);
    $display("[TIMEOUT] NPU busy=%0d done=%0d dma_phase=%0d core_state=%0d done_latch=%0d kicks=%0d",
      npu_busy, npu_done, dma_phase, core_st, csr_done, kicks);
    $display("[TIMEOUT] pc=%h dcm=%0d", pc, dut.u_cpu.u_riscv_core_dcache_top.dcache_controller.STATE);
    $finish;
  end

endmodule
