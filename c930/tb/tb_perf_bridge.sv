// tb_perf_bridge.sv — Test the MMIO bridge with minimal perf firmware.
// Loads perf_only.hex (skips all stress tests) and monitors the NPU.

`timescale 1ns/1ps

module tb_perf_bridge;

  reg         clk = 0;
  reg         rst_n = 0;
  reg  [31:0] cycle = 0;

  always #5 clk = ~clk;
  always @(posedge clk) cycle <= cycle + 1;

  c930_soc_top #(.MAX_M(8), .MAX_K(16), .MAX_N(12)) dut (
    .i_clk(clk), .i_rst_n(rst_n)
  );

  // Load perf_only firmware (32-bit word hex -> 8-bit byte DDR)
  logic [31:0] img [0:1023];
  initial begin
    int i;
    for (i = 0; i < 1024; i++) img[i] = 32'h0;
    $readmemh("sw/perf_only.hex", img);
    for (i = 0; i < 1024; i++) begin
      dut.u_ddr.mem[4*i + 0] = img[i][7:0];
      dut.u_ddr.mem[4*i + 1] = img[i][15:8];
      dut.u_ddr.mem[4*i + 2] = img[i][23:16];
      dut.u_ddr.mem[4*i + 3] = img[i][31:24];
    end
  end

  // Preload A/B data for M=2 N=3 K=4 INT8 (small, fast)
  initial begin
    // A (2x4): {1,2,3,4,5,6,7,8}
    dut.u_ddr.mem[32'h8000] = 8'h01; dut.u_ddr.mem[32'h8001] = 8'h02;
    dut.u_ddr.mem[32'h8002] = 8'h03; dut.u_ddr.mem[32'h8003] = 8'h04;
    dut.u_ddr.mem[32'h8004] = 8'h05; dut.u_ddr.mem[32'h8005] = 8'h06;
    dut.u_ddr.mem[32'h8006] = 8'h07; dut.u_ddr.mem[32'h8007] = 8'h08;
    // B (4x3): identity-ish
    dut.u_ddr.mem[32'h8400] = 8'h01; dut.u_ddr.mem[32'h8401] = 8'h00; dut.u_ddr.mem[32'h8402] = 8'h00;
    dut.u_ddr.mem[32'h8403] = 8'h00; dut.u_ddr.mem[32'h8404] = 8'h01; dut.u_ddr.mem[32'h8405] = 8'h00;
    dut.u_ddr.mem[32'h8406] = 8'h01; dut.u_ddr.mem[32'h8407] = 8'h00; dut.u_ddr.mem[32'h8408] = 8'h01;
    dut.u_ddr.mem[32'h8409] = 8'h00; dut.u_ddr.mem[32'h840a] = 8'h00; dut.u_ddr.mem[32'h840b] = 8'h00;
    // Clear done, DIMS
    dut.u_ddr.mem[32'h9410] = 8'h00; dut.u_ddr.mem[32'h9411] = 8'h00;
    dut.u_ddr.mem[32'h9412] = 8'h00; dut.u_ddr.mem[32'h9413] = 8'h00;
    dut.u_ddr.mem[32'h9490] = 8'h00;
  end

  // Monitor signals
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
      $display("[KICK] t=%0d prec=%0d M=%0d N=%0d K=%0d A=%h B=%h C=%h",
        cycle,
        dut.u_npu.u_csr.precision,
        dut.u_npu.u_csr.dim_m, dut.u_npu.u_csr.dim_n, dut.u_npu.u_csr.dim_k,
        dut.u_npu.u_csr.a_base, dut.u_npu.u_csr.b_base, dut.u_npu.u_csr.c_base);
      $fflush();
    end
  end

  // Track done
  always @(posedge clk) begin
    if (npu_done) begin
      $display("[DONE] t=%0d dma_phase=%0d core_state=%0d", cycle, dma_phase, core_st);
      $fflush();
    end
  end

  // Track phase register changes
  reg [7:0] last_phase;
  always @(posedge clk) begin
    last_phase <= dut.u_ddr.mem[32'h9490];
    if (dut.u_ddr.mem[32'h9490] != last_phase && cycle > 100) begin
      $display("[PHASE] t=%0d phase -> %02h", cycle, dut.u_ddr.mem[32'h9490]);
      $fflush();
    end
  end

  // Track dcache state when MMIO
  reg [3:0] last_dcm;
  always @(posedge clk) begin
    last_dcm <= dut.u_cpu.u_riscv_core_dcache_top.dcache_controller.STATE;
    if (dut.u_cpu.u_riscv_core_dcache_top.dcache_controller.STATE != last_dcm &&
        (dut.u_cpu.u_riscv_core_dcache_top.dcache_controller.STATE == 4'b0101 ||
         dut.u_cpu.u_riscv_core_dcache_top.dcache_controller.STATE == 4'b0110 ||
         dut.u_cpu.u_riscv_core_dcache_top.dcache_controller.STATE == 4'b0111 ||
         last_dcm == 4'b0101 || last_dcm == 4'b0110 || last_dcm == 4'b0111)) begin
      $display("[DCMMIO] t=%0d state %0d->%0d stall=%0d wr_v=%0d rd_req=%0d wr_done=%0d rd_done=%0d",
        cycle, last_dcm, dut.u_cpu.u_riscv_core_dcache_top.dcache_controller.STATE,
        dut.u_cpu.hu_stall_if,
        dut.u_cpu.u_riscv_core_dcache_top.dcache_controller.o_mmio_write_valid,
        dut.u_cpu.u_riscv_core_dcache_top.dcache_controller.o_mmio_read_req,
        dut.u_cpu.u_riscv_core_dcache_top.dcache_controller.i_mmio_write_done,
        dut.u_cpu.u_riscv_core_dcache_top.dcache_controller.i_mmio_read_done);
      $fflush();
    end
  end

  initial begin
    rst_n = 0;
    repeat(20) @(posedge clk);
    rst_n = 1;
    $display("[BOOT] t=%0d", cycle);
    $fflush();

    // Wait for phase 0x01 (main started)
    wait(dut.u_ddr.mem[32'h9490] == 8'h01);
    $display("[MAIN] t=%0d C driver started", cycle);

    // Wait for first NPU kick
    wait(kicks >= 1);
    $display("[WAIT] t=%0d First NPU kick seen, waiting for done...", cycle);

    // Wait for phase 0x08 (first GEMM done) or timeout
    begin : wait_done1
      integer t = 0;
      while (dut.u_ddr.mem[32'h9490] != 8'h08 && t < 100000) begin
        @(posedge clk); t = t + 1;
      end
      if (dut.u_ddr.mem[32'h9490] == 8'h08)
        $display("[GEMM1] t=%0d DONE! kicks=%0d", cycle, kicks);
      else
        $display("[GEMM1] t=%0d TIMEOUT! phase=%02h kicks=%0d dma=%0d core=%0d busy=%0d donelatch=%0d",
          cycle, dut.u_ddr.mem[32'h9490], kicks, dma_phase, core_st, npu_busy, csr_done);
    end

    // Wait for phase 0x10 (perf_bench started) or 0xA0 (first perf case)
    begin : wait_perf
      integer t = 0;
      while (dut.u_ddr.mem[32'h9490] != 8'h10 && dut.u_ddr.mem[32'h9490] != 8'hA0 && t < 100000) begin
        @(posedge clk); t = t + 1;
      end
      $display("[PERF] t=%0d perf_bench entered, phase=%02h kicks=%0d", cycle, dut.u_ddr.mem[32'h9490], kicks);
    end

    // Wait for second NPU kick (perf_bench's first GEMM)
    begin : wait_kick2
      integer t = 0;
      while (kicks < 2 && t < 500000) begin
        @(posedge clk); t = t + 1;
      end
      if (kicks >= 2)
        $display("[KICK2] t=%0d Second NPU kick seen! dma=%0d core=%0d busy=%0d donelatch=%0d",
          cycle, dma_phase, core_st, npu_busy, csr_done);
      else
        $display("[KICK2] t=%0d TIMEOUT waiting for second kick! phase=%02h dma=%0d core=%0d busy=%0d donelatch=%0d pc=%h",
          cycle, dut.u_ddr.mem[32'h9490], dma_phase, core_st, npu_busy, csr_done, pc);
    end

    // If we got the second kick, wait for it to complete
    if (kicks >= 2) begin
      begin : wait_done2
        integer t = 0;
        while (csr_done != 1 && t < 100000) begin
          @(posedge clk); t = t + 1;
        end
        if (csr_done)
          $display("[PERF-DONE] t=%0d NPU completed second GEMM! dma=%0d core=%0d",
            cycle, dma_phase, core_st);
        else
          $display("[PERF-STUCK] t=%0d NPU stuck! dma=%0d core=%0d launched=%0d t_cnt=%0d",
            cycle, dma_phase, core_st, dut.u_npu.u_dma.launched, dut.u_npu.u_core.t);
      end
    end

    // Final status
    $display("");
    $display("=== RESULT ===");
    $display("  kicks=%0d done_latch=%0d phase=%02h", kicks, csr_done, dut.u_ddr.mem[32'h9490]);
    $display("  NPU busy=%0d done=%0d dma_phase=%0d core_state=%0d", npu_busy, npu_done, dma_phase, core_st);
    $display("  pc=%h", pc);
    $display("=============");
    $finish;
  end

  initial begin
    #20000000;
    $display("[TIMEOUT] Global timeout at t=%0d", cycle);
    $display("  kicks=%0d done_latch=%0d phase=%02h", kicks, csr_done, dut.u_ddr.mem[32'h9490]);
    $display("  NPU busy=%0d done=%0d dma_phase=%0d core_state=%0d", npu_busy, npu_done, dma_phase, core_st);
    $display("  pc=%h", pc);
    $finish;
  end

endmodule
