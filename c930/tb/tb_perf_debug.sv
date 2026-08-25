// tb_perf_debug.sv — Minimal testbench to debug NPU perf_bench failure.
// Runs the full C driver (which includes perf_bench after DONE) and
// monitors NPU internal signals when the core is stuck polling.

`timescale 1ns/1ps

module tb_perf_debug;

  reg        clk = 0;
  reg        rst_n = 0;
  reg [31:0] cycle = 0;

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

  // Monitor NPU CSR signals
  wire        npu_busy  = dut.u_npu.o_busy;
  wire        npu_done  = dut.u_npu.o_done;
  wire [2:0]  dma_phase = dut.u_npu.u_dma.phase;
  wire [2:0]  core_st   = dut.u_npu.u_core.state;
  wire        csr_start = dut.u_npu.u_csr.start_pulse;
  wire        csr_done  = dut.u_npu.u_csr.done_latch;
  wire [2:0]  csr_prec  = dut.u_npu.u_csr.precision;
  wire [15:0] csr_dm    = dut.u_npu.u_csr.dim_m;
  wire [15:0] csr_dn    = dut.u_npu.u_csr.dim_n;
  wire [15:0] csr_dk    = dut.u_npu.u_csr.dim_k;
  wire [31:0] csr_abase = dut.u_npu.u_csr.a_base;
  wire [31:0] csr_bbase = dut.u_npu.u_csr.b_base;
  wire [31:0] csr_cbase = dut.u_npu.u_csr.c_base;
  wire [31:0] pc        = dut.u_cpu.if_pipe_pcf_new;

  // Track the NPU kick count
  integer kicks = 0;
  always @(posedge clk) begin
    if (csr_start) begin
      kicks <= kicks + 1;
      $display("[KICK #%0d] t=%0d prec=%0d M=%0d N=%0d K=%0d A=%h B=%h C=%h",
        kicks, cycle, csr_prec, csr_dm, csr_dn, csr_dk,
        csr_abase, csr_bbase, csr_cbase);
      $fflush();
    end
  end

  // Detect when core enters the perf polling loop (PC 0x110-0x120)
  reg perf_polling = 0;
  always @(posedge clk) begin
    if (pc >= 32'h110 && pc <= 32'h120 && !perf_polling) begin
      perf_polling <= 1;
      $display("[PERF-POLL] t=%0d Core entering perf polling loop. NPU busy=%0d done=%0d dma_phase=%0d core_state=%0d",
        cycle, npu_busy, npu_done, dma_phase, core_st);
      $fflush();
    end
    if (pc < 32'h110 || pc > 32'h120)
      perf_polling <= 0;
  end

  // When NPU is stuck (DMA in P_IDLE, core in S_IDLE, but done never fires)
  // dump state every 10000 cycles
  reg first_diag = 0;
  always @(posedge clk) begin
    if (perf_polling && cycle[13:0] == 0) begin
      $display("[NPU-STUCK] t=%0d busy=%0d done=%0d dma=%0d core=%0d start=%0d donelatch=%0d prec=%0d M=%0d N=%0d K=%0d",
        cycle, npu_busy, npu_done, dma_phase, core_st, csr_start, csr_done, csr_prec, csr_dm, csr_dn, csr_dk);
      $fflush();
    end
  end

  // End simulation after enough cycles
  initial begin
    rst_n = 0;
    repeat(20) @(posedge clk);
    rst_n = 1;
    // Wait for NPU done or timeout
    repeat(50_000_000) begin
      @(posedge clk);
      // Check if we see the perf results in DDR
      if (dut.u_ddr.mem[32'h9500] != 8'h00 && first_diag == 0) begin
        $display("[PERF-RESULT] t=%0d PERF_RES[0]=%h%h%h%h",
          cycle,
          dut.u_ddr.mem[32'h9503], dut.u_ddr.mem[32'h9502],
          dut.u_ddr.mem[32'h9501], dut.u_ddr.mem[32'h9500]);
        first_diag <= 1;
      end
    end
    $display("[TIMEOUT] Simulation ended after 50M cycles");
    $finish;
  end

  // Early termination on $finish
  initial begin
    #0;
    $dumpfile("build/vcd/tb_perf_debug.vcd");
    $dumpvars(0, tb_perf_debug);
  end

endmodule
