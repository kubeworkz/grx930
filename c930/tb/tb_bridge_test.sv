// tb_bridge_test.sv — Loads bridge_test.hex, boots core, monitors the full
// CPU → dcache → MMIO bridge → NPU CSR path for a single GEMM kick.
// Diagnoses why the CPU-path MMIO writes stall on re-trigger.

`timescale 1ns/1ps

module tb_bridge_test;

  reg         clk = 0;
  reg         rst_n = 0;
  reg  [31:0] cycle = 0;

  always #5 clk = ~clk; // 100 MHz
  always @(posedge clk) cycle <= cycle + 1;

  c930_soc_top #(.MAX_M(8), .MAX_K(16), .MAX_N(12)) dut (
    .i_clk   (clk),
    .i_rst_n (rst_n)
  );

  // Load bridge_test firmware (32-bit word hex → 8-bit byte DDR)
  logic [31:0] img [0:1023];
  initial begin
    int i;
    for (i = 0; i < 1024; i++) img[i] = 32'h0;
    $readmemh("sw/bridge_test2.hex", img);
    for (i = 0; i < 1024; i++) begin
      dut.u_ddr.mem[4*i + 0] = img[i][7:0];
      dut.u_ddr.mem[4*i + 1] = img[i][15:8];
      dut.u_ddr.mem[4*i + 2] = img[i][23:16];
      dut.u_ddr.mem[4*i + 3] = img[i][31:24];
    end
  end

  // Preload A/B for M=8 N=8 K=16 INT8 (identity-ish)
  initial begin
    int i;
    for (i = 0; i < 512; i++) begin
      dut.u_ddr.mem[32'h8000 + i] = (i < 128) ? 8'h01 : 8'h00; // A
      dut.u_ddr.mem[32'h8400 + i] = (i < 128) ? 8'h01 : 8'h00; // B
      dut.u_ddr.mem[32'h8800 + i] = 8'h00;                      // C
    end
    // Clear phase/done
    dut.u_ddr.mem[32'h9490] = 8'h00;
    dut.u_ddr.mem[32'h9410] = 8'h00;
  end

  // ---- Monitors ----
  wire [31:0] pc        = dut.u_cpu.if_pipe_pcf_new;

  // Bridge FSM
  wire [2:0]  br_st     = dut.u_mmio_bridge.state;
  wire        br_awv    = dut.u_mmio_bridge.m_axi_awvalid;
  wire        br_wv     = dut.u_mmio_bridge.m_axi_wvalid;
  wire        br_brdy   = dut.u_mmio_bridge.m_axi_bready;
  wire        br_bval   = dut.u_mmio_bridge.m_axi_bvalid;
  wire        br_done   = dut.u_mmio_bridge.o_mmio_write_done;
  wire        br_rdone  = dut.u_mmio_bridge.o_mmio_read_done;

  // Dcache MMIO
  wire [3:0]  dcm_st    = dut.u_cpu.u_riscv_core_dcache_top.dcache_controller.STATE;
  wire        dcm_wv    = dut.u_cpu.u_riscv_core_dcache_top.dcache_controller.o_mmio_write_valid;
  wire        dcm_wd    = dut.u_cpu.u_riscv_core_dcache_top.dcache_controller.i_mmio_write_done;
  wire        dcm_rr    = dut.u_cpu.u_riscv_core_dcache_top.dcache_controller.o_mmio_read_req;
  wire        dcm_rd    = dut.u_cpu.u_riscv_core_dcache_top.dcache_controller.i_mmio_read_done;
  wire        dcm_stall = dut.u_cpu.hu_stall_if;

  // NPU CSR
  wire        csr_bval2  = dut.u_npu.u_csr.s_axi_bvalid;
  wire        csr_start = dut.u_npu.u_csr.start_pulse;
  wire        csr_busy  = dut.u_npu.o_busy;
  wire        csr_done  = dut.u_npu.u_csr.done_latch;
  wire [3:0]  dma_ph    = dut.u_npu.u_dma.phase;
  wire [3:0]  core_st   = dut.u_npu.u_core.state;

  // ---- Trace bridge state changes ----
  reg [2:0] last_br;
  always @(posedge clk) begin
    last_br <= br_st;
    if (br_st != last_br && cycle > 50) begin
      $display("[BRG] t=%0d %0d->%0d awv=%0d wv=%0d brd=%0d bval=%0d done=%0d",
        cycle, last_br, br_st, br_awv, br_wv, br_brdy, br_bval, br_done);
      $fflush();
    end
  end

  // ---- Trace dcache MMIO state changes ----
  reg [3:0] last_dcm;
  always @(posedge clk) begin
    last_dcm <= dcm_st;
    if (dcm_st != last_dcm && cycle > 50) begin
      $display("[DCM] t=%0d %0d->%0d wv=%0d wd=%0d rr=%0d rd=%0d stall=%0d",
        cycle, last_dcm, dcm_st, dcm_wv, dcm_wd, dcm_rr, dcm_rd, dcm_stall);
      $fflush();
    end
  end

  // ---- Trace NPU events ----
  always @(posedge clk) begin
    if (csr_start) begin
      $display("[KICK] t=%0d prec=%0d M=%0d N=%0d K=%0d A=%h B=%0d C=%h",
        cycle,
        dut.u_npu.u_csr.precision,
        dut.u_npu.u_csr.dim_m,
        dut.u_npu.u_csr.dim_n,
        dut.u_npu.u_csr.dim_k,
        dut.u_npu.u_csr.a_base,
        dut.u_npu.u_csr.b_base,
        dut.u_npu.u_csr.c_base);
      $fflush();
    end
    if (csr_done) begin
      $display("[DONE] t=%0d dma=%0d core=%0d", cycle, dma_ph, core_st);
      $fflush();
    end
  end

  // ---- Trace phase register ----
  reg [7:0] last_phase;
  always @(posedge clk) begin
    last_phase <= dut.u_ddr.mem[32'h9490];
    if (dut.u_ddr.mem[32'h9490] != last_phase && cycle > 100) begin
      $display("[PHASE] t=%0d -> 0x%02h", cycle, dut.u_ddr.mem[32'h9490]);
      $fflush();
    end
  end

  // ---- Test body ----
  initial begin
    rst_n = 0;
    repeat(20) @(posedge clk);
    rst_n = 1;
    $display("[BOOT] t=%0d bridge_test firmware loaded", cycle);
    $fflush();

    // Wait for DONE signal
    begin : wd
      integer t = 0;
      while (dut.u_ddr.mem[32'h9410] != 8'hEF || dut.u_ddr.mem[32'h9411] != 8'hBE || dut.u_ddr.mem[32'h9412] != 8'hAD || dut.u_ddr.mem[32'h9413] != 8'hDE) begin
        @(posedge clk);
        t = t + 1;
        if (t > 1000000) begin
          $display("[TIMEOUT] t=%0d DONE never seen. phase=%02h pc=%h dcm=%0d br=%0d npu_busy=%0d npu_done=%0d csr_done=%0d dma=%0d core=%0d",
            cycle, dut.u_ddr.mem[32'h9490], pc, dcm_st, br_st, csr_busy, dut.u_npu.o_done, csr_done, dma_ph, core_st);
          // Dump PC trace
          $display("[TRACE] Last 5 PCs were sampled; check VCD for full trace.");
          $finish;
        end
      end
      $display("[PASS] t=%0d DONE seen after %0d cycles", cycle, t);
    end

    // Summary
    $display("");
    $display("=== BRIDGE TEST RESULT ===");
    $display("  phase=%02h pc=%h dma=%0d core=%0d npu_busy=%0d csr_done=%0d",
      dut.u_ddr.mem[32'h9490], pc, dma_ph, core_st, csr_busy, csr_done);
    $display("  C[0..3] = %02h %02h %02h %02h",
      dut.u_ddr.mem[32'h8800], dut.u_ddr.mem[32'h8801],
      dut.u_ddr.mem[32'h8802], dut.u_ddr.mem[32'h8803]);
    $display("==========================");
    $finish;
  end

  // Timeout
  initial begin
    #20000000;
    $display("[TIMEOUT] Global timeout at t=%0d phase=%02h pc=%h dcm=%0d br=%0d npu_busy=%0d csr_done=%0d dma=%0d core=%0d",
      cycle, dut.u_ddr.mem[32'h9490], pc, dcm_st, br_st, csr_busy, csr_done, dma_ph, core_st);
    $finish;
  end

endmodule
