// -----------------------------------------------------------------------------
// tb_c930_soc.sv
//
// End-to-end SoC test with a randomized M/N/K sweep through the full path
// (RV64IMAC core -> MMIO bridge -> NPU CSR -> AXI4 DMA -> DDR).
//
// For every case the testbench:
//   1. preloads random INT8 A (MxK) and B (KxN) into DDR at the buffer bases,
//   2. writes the workload descriptor (M, N, K) to DIMS_ADDR,
//   3. reboots the core, which runs the C driver (npu_test.c): it reads the
//      dims from DDR, programs the NPU over MMIO, launches the GEMM, and
//      writes a completion magic to DONE_ADDR,
//   4. waits for the magic, then reads A/B/C back from the DDR model and
//      verifies C against a reference GEMM.
//
// Operand bytes come from a deterministic LCG seeded per case, so any failure
// is reproducible.
//
// Image format: sw/npu_prog.hex, one 32-bit little-endian word per line.
// -----------------------------------------------------------------------------
module tb_c930_soc;

  // Must track the DUT instantiation in c930_soc_top.
  localparam int NUM_ROWS = 4;   // systolic rows (reduction per pass)
  localparam int NUM_COLS = 4;   // systolic cols (output width)
  localparam int MAX_M    = 8;
  localparam int MAX_K    = 16;
  localparam int MAX_N    = 12;  // > NUM_COLS so the sweep exercises N-tiling

  // DDR workload layout (byte addresses, shared with sw/npu_test.c)
  localparam int A_ADDR    = 32'h9000;
  localparam int B_ADDR    = 32'h9100;
  localparam int C_ADDR    = 32'h9200;
  localparam int DIMS_ADDR = 32'h9400;
  localparam int DONE_ADDR = 32'h9410;

  localparam int MEM_BYTES = 65536;
  localparam int IMG_WORDS = 4096;   // program image is small; operands are TB-loaded

  logic clk   = 1'b0;
  logic rst_n = 1'b0;

  logic o_npu_busy, o_npu_done, o_npu_error, o_npu_irq;

  // ---------------------------------------------------------------------------
  // DUT
  // ---------------------------------------------------------------------------
  c930_soc_top #(
    .NUM_ROWS  (NUM_ROWS),
    .NUM_COLS  (NUM_COLS),
    .MAX_M     (MAX_M),
    .MAX_K     (MAX_K),
    .MAX_N     (MAX_N),
    .MEM_BYTES (MEM_BYTES)
  ) dut (
    .i_clk        (clk),
    .i_rst_n      (rst_n),
    .o_npu_busy   (o_npu_busy),
    .o_npu_done   (o_npu_done),
    .o_npu_error  (o_npu_error),
    .o_npu_irq    (o_npu_irq)
  );

  // ---------------------------------------------------------------------------
  // Clock
  // ---------------------------------------------------------------------------
  always #5 clk = ~clk;

  // ---------------------------------------------------------------------------
  // Deterministic operand generator (LCG; glibc constants)
  // ---------------------------------------------------------------------------
  function automatic logic [31:0] lcg(input logic [31:0] x);
    logic [63:0] t;
    t   = 64'd1103515245 * x + 64'd12345;
    lcg = t[31:0];
  endfunction

  // ---------------------------------------------------------------------------
  // Image loading
  // ---------------------------------------------------------------------------
  logic [31:0] img [0:IMG_WORDS-1];

  task automatic load_image();
    int i;
    $display("[TEST] loading sw/npu_prog.hex");
    for (i = 0; i < IMG_WORDS; i++) img[i] = 32'h0;
    $readmemh("sw/npu_prog.hex", img);

    for (i = 0; i < MEM_BYTES; i++) dut.u_ddr.mem[i] = 8'h0;

    for (i = 0; i < IMG_WORDS; i++) begin
      dut.u_ddr.mem[4*i + 0] = img[i][7:0];
      dut.u_ddr.mem[4*i + 1] = img[i][15:8];
      dut.u_ddr.mem[4*i + 2] = img[i][23:16];
      dut.u_ddr.mem[4*i + 3] = img[i][31:24];
    end
  endtask

  // ---------------------------------------------------------------------------
  // Workload injection: random INT8 A/B, dims descriptor, clear completion magic
  // ---------------------------------------------------------------------------
  task automatic fill_ab(input int m, n, k, input int seed);
    logic [31:0] s;
    s = seed;
    for (int i = 0; i < m * k; i++) begin
      s = lcg(s);
      dut.u_ddr.mem[A_ADDR + i] = s[7:0];   // INT8 lane, little-endian packing
    end
    for (int i = 0; i < k * n; i++) begin
      s = lcg(s);
      dut.u_ddr.mem[B_ADDR + i] = s[7:0];
    end
  endtask

  task automatic write_dims(input int m, n, k);
    dut.u_ddr.mem[DIMS_ADDR +  0] = m[7:0];
    dut.u_ddr.mem[DIMS_ADDR +  1] = m[15:8];
    dut.u_ddr.mem[DIMS_ADDR +  2] = 8'h00;
    dut.u_ddr.mem[DIMS_ADDR +  3] = 8'h00;
    dut.u_ddr.mem[DIMS_ADDR +  4] = n[7:0];
    dut.u_ddr.mem[DIMS_ADDR +  5] = n[15:8];
    dut.u_ddr.mem[DIMS_ADDR +  6] = 8'h00;
    dut.u_ddr.mem[DIMS_ADDR +  7] = 8'h00;
    dut.u_ddr.mem[DIMS_ADDR +  8] = k[7:0];
    dut.u_ddr.mem[DIMS_ADDR +  9] = k[15:8];
    dut.u_ddr.mem[DIMS_ADDR + 10] = 8'h00;
    dut.u_ddr.mem[DIMS_ADDR + 11] = 8'h00;
  endtask

  task automatic clear_done();
    dut.u_ddr.mem[DONE_ADDR + 0] = 8'h00;
    dut.u_ddr.mem[DONE_ADDR + 1] = 8'h00;
    dut.u_ddr.mem[DONE_ADDR + 2] = 8'h00;
    dut.u_ddr.mem[DONE_ADDR + 3] = 8'h00;
  endtask

  // Poll the DDR for the completion magic written by the C program.
  task automatic wait_done(output int found);
    int timeout = 0;
    found = 0;
    while (!found && timeout < 2000000) begin
      @(posedge clk);
      timeout = timeout + 1;
      if (dut.u_ddr.mem[DONE_ADDR + 3] == 8'hDE &&
          dut.u_ddr.mem[DONE_ADDR + 2] == 8'hAD &&
          dut.u_ddr.mem[DONE_ADDR + 1] == 8'hBE &&
          dut.u_ddr.mem[DONE_ADDR + 0] == 8'hEF)
        found = 1;
    end
  endtask

  // ---------------------------------------------------------------------------
  // Reference check (reads A/B/C back from the DDR model)
  // ---------------------------------------------------------------------------
  task automatic check_gemm(input int m, n, k);
    int errors = 0;
    int sum;
    int got;

    for (int mi = 0; mi < m; mi++) begin
      for (int ni = 0; ni < n; ni++) begin
        sum = 0;
        for (int ki = 0; ki < k; ki++) begin
          int av = $signed(dut.u_ddr.mem[A_ADDR + mi*k + ki]);
          int bv = $signed(dut.u_ddr.mem[B_ADDR + ki*n + ni]);
          sum = sum + av * bv;
        end

        // C is stored as little-endian INT32 words.
        got = $signed({dut.u_ddr.mem[C_ADDR + (mi*n+ni)*4 + 3],
                       dut.u_ddr.mem[C_ADDR + (mi*n+ni)*4 + 2],
                       dut.u_ddr.mem[C_ADDR + (mi*n+ni)*4 + 1],
                       dut.u_ddr.mem[C_ADDR + (mi*n+ni)*4 + 0]});

        if (got != sum) begin
          $display("[FAIL] C[%0d][%0d] = %0d, expected %0d", mi, ni, got, sum);
          errors = errors + 1;
        end
      end
    end

    if (errors != 0)
      $fatal(1, "[FAIL] GEMM M=%0d N=%0d K=%0d: %0d mismatches", m, n, k, errors);
    $display("[PASS] GEMM M=%0d N=%0d K=%0d verified (C read back from DDR)", m, n, k);
  endtask

  // ---------------------------------------------------------------------------
  // One full end-to-end case: inject workload, reboot the core, verify.
  // ---------------------------------------------------------------------------
  task automatic run_case(input int m, n, k, input int seed);
    int found;
    $display("[TEST] M=%0d N=%0d K=%0d (seed %0d)", m, n, k, seed);
    $fflush();
    fill_ab(m, n, k, seed);
    write_dims(m, n, k);
    clear_done();

    // Reboot the core so it re-runs the C driver against the new workload.
    rst_n = 1'b0;
    repeat (8) @(posedge clk);
    rst_n = 1'b1;

    wait_done(found);
    if (!found)
      $fatal(1, "[FAIL] M=%0d N=%0d K=%0d: CPU never signaled completion", m, n, k);
    if (o_npu_error)
      $fatal(1, "[FAIL] M=%0d N=%0d K=%0d: NPU reported an error", m, n, k);
    repeat (4) @(posedge clk);   // let the final stores settle
    check_gemm(m, n, k);
  endtask

  // Randomized (but deterministic) M/N/K sweep across the supported space.
  task automatic run_sweep(input int num_cases);
    logic [31:0] s = 32'hDEADBEEF;
    int m, n, k;
    for (int c = 0; c < num_cases; c++) begin
      s = lcg(s); m = (s % MAX_M) + 1;
      s = lcg(s); n = (s % MAX_N) + 1;
      s = lcg(s); k = (s % MAX_K) + 1;
      run_case(m, n, k, 5000 + c);
    end
  endtask

  // ---------------------------------------------------------------------------
  // Main
  // ---------------------------------------------------------------------------
  initial begin
    $timeformat(-9, 0, " ns", 8);
    // VCD dump disabled for the full sweep (dumping dominates runtime);
    // re-enable with `make wave` for waveform debugging.
    // $dumpfile("build/soc_storm3.vcd");
    // $dumpvars(0, dut.u_cpu);

    load_image();
    // Keep the core in reset until the first run_case pulses it, so the CPU
    // never boots against a partially-initialized workload.
    rst_n = 1'b0;

    // ---- Explicit edge cases (through the full core+MMIO+DMA+DDR path) ----
    run_case(1, 1, 1, 1001);    // minimal: M=1, K=1
    run_case(2, 3, 1, 1002);    // K=1 -> single partial tile (kr=1)
    run_case(8, 12, 1, 1003);   // max M/N with K=1
    run_case(1, 4, 4, 1004);    // M=1, K == NUM_ROWS (one full tile)
    run_case(8, 4, 4, 1005);    // K == NUM_ROWS exactly
    run_case(3, 4, 8, 1006);    // K == 2 * NUM_ROWS
    run_case(2, 3, 16, 1007);   // K == MAX_K == 4 * NUM_ROWS
    run_case(1, 2, 5, 1008);    // M=1 with a partial K tile (kr=1)
    run_case(5, 11, 7, 1009);   // N > NUM_COLS (N-tiling) + partial K tile
    run_case(8, 12, 16, 1010);  // max dims: 3 N-tiles x 4 K-tiles
    run_case(1, 12, 1, 1011);   // M=1, K=1, 3 N-tiles
    run_case(2, 6, 9, 1012);    // odd K-tiling (kr=1) + N-tiling

    // ---- Randomized M/N/K sweep ----
    run_sweep(10);

    $display("[PASS] all SoC NPU tests passed");
    $finish;
  end

  // Failsafe watchdog
  initial begin
    #20000000;
    $display("[FAIL] watchdog timeout");
    $fatal(1, "timeout");
  end

  // Cheap liveness marker: every 1000 cycles print the CPU PC and NPU done so
  // a hang is visible immediately.
  integer lv_edges = 0;
  always @(posedge clk) begin
    lv_edges = lv_edges + 1;
    if ((lv_edges % 1000) == 0) begin
      $display("[LV] %0d cycles pc=%h stl_if=%b dcm=%0d npudone=%b",
        lv_edges,
        dut.u_cpu.if_pipe_pcf_new,
        dut.u_cpu.hu_stall_if,
        dut.u_cpu.u_riscv_core_dcache_top.dcache_controller.STATE,
        dut.u_npu.o_done);
      $fflush();
    end
  end

endmodule
