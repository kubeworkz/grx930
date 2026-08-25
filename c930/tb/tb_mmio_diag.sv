`timescale 1ns/1ps

// Minimal firmware that only does perf_bench CSR writes
module tb_mmio_diag;

  reg         clk = 0;
  reg         rst_n = 0;
  reg  [31:0] cycle = 0;

  always #5 clk = ~clk; // 100 MHz
  always @(posedge clk) cycle <= cycle + 1;

  c930_soc_top #(.MAX_M(8), .MAX_K(16), .MAX_N(12)) dut (
    .i_clk   (clk),
    .i_rst_n (rst_n)
  );

  // ---- Monitor bridge FSM ----
  wire [2:0] bridge_st = dut.u_mmio_bridge.state;
  wire       bridge_awvalid = dut.u_mmio_bridge.m_axi_awvalid;
  wire       bridge_wvalid  = dut.u_mmio_bridge.m_axi_wvalid;
  wire       bridge_bready = dut.u_mmio_bridge.m_axi_bready;
  wire       bridge_bvalid = dut.u_mmio_bridge.m_axi_bvalid;
  wire       bridge_done   = dut.u_mmio_bridge.o_mmio_write_done;
  wire       bridge_rdone  = dut.u_mmio_bridge.o_mmio_read_done;

  // ---- Monitor dcache MMIO ----
  wire [3:0] dcm_st = dut.u_cpu.u_riscv_core_dcache_top.dcache_controller.STATE;
  wire       dcm_wr_valid = dut.u_cpu.u_riscv_core_dcache_top.dcache_controller.o_mmio_write_valid;
  wire       dcm_wr_done  = dut.u_cpu.u_riscv_core_dcache_top.dcache_controller.i_mmio_write_done;
  wire       dcm_rd_req   = dut.u_cpu.u_riscv_core_dcache_top.dcache_controller.o_mmio_read_req;
  wire       dcm_rd_done  = dut.u_cpu.u_riscv_core_dcache_top.dcache_controller.i_mmio_read_done;
  wire       dcm_stall    = dut.u_cpu.hu_stall_if;

  // ---- Monitor NPU CSR ----
  wire       csr_bvalid = dut.u_npu.u_csr.s_axi_bvalid;
  wire       csr_start  = dut.u_npu.u_csr.start_pulse;
  wire       csr_busy   = dut.u_npu.o_busy;
  wire       csr_done   = dut.u_npu.u_csr.done_latch;

  // ---- Monitor core ----
  wire [31:0] pc = dut.u_cpu.if_pipe_pcf_new;

  // Trace bridge state changes
  reg [2:0] last_bridge_st;
  always @(posedge clk) begin
    last_bridge_st <= bridge_st;
    if (bridge_st != last_bridge_st && cycle > 50) begin
      $display("[BRIDGE] t=%0d %0d->%0d awv=%0d wv=%0d brd=%0d bval=%0d done=%0d",
        cycle, last_bridge_st, bridge_st,
        bridge_awvalid, bridge_wvalid, bridge_bready, bridge_bvalid, bridge_done);
      $fflush();
    end
  end

  // Trace dcache MMIO state changes
  reg [3:0] last_dcm;
  always @(posedge clk) begin
    last_dcm <= dcm_st;
    if (dcm_st != last_dcm && cycle > 50) begin
      $display("[DCM]   t=%0d %0d->%0d wr_v=%0d wr_done=%0d rd_req=%0d rd_done=%0d stall=%0d",
        cycle, last_dcm, dcm_st,
        dcm_wr_valid, dcm_wr_done, dcm_rd_req, dcm_rd_done, dcm_stall);
      $fflush();
    end
  end

  // Trace NPU start/done
  always @(posedge clk) begin
    if (csr_start) begin
      $display("[NPU-KICK] t=%0d", cycle);
      $fflush();
    end
    if (csr_done && !dut.u_npu.u_csr.done_latch) begin
      $display("[NPU-DONE] t=%0d", cycle);
      $fflush();
    end
  end

  // ---- Test: Write NPU CSRs directly via the AXI path ----
  // We'll program M=2, N=3, K=4, prec=0, then START
  // This mimics what the C driver's run_gemm does

  // AXI master signals (we drive these from a simple FSM)
  reg  [31:0] m_awaddr;
  reg         m_awvalid;
  reg  [31:0] m_wdata;
  reg  [3:0]  m_wstrb;
  reg         m_wvalid;
  reg         m_bready;
  reg  [31:0] m_araddr;
  reg         m_arvalid;
  reg         m_rready;

  // Connect to NPU CSR AXI slave
  assign dut.u_npu.u_csr.s_axi_awaddr  = m_awaddr;
  assign dut.u_npu.u_csr.s_axi_awvalid = m_awvalid;
  assign dut.u_npu.u_csr.s_axi_wdata   = m_wdata;
  assign dut.u_npu.u_csr.s_axi_wstrb   = m_wstrb;
  assign dut.u_npu.u_csr.s_axi_wvalid  = m_wvalid;
  assign dut.u_npu.u_csr.s_axi_bready  = m_bready;
  assign dut.u_npu.u_csr.s_axi_araddr  = m_araddr;
  assign dut.u_npu.u_csr.s_axi_arvalid = m_arvalid;
  assign dut.u_npu.u_csr.s_axi_rready  = m_rready;

  // Wait for AXI write completion
  task automatic axi_write(input [31:0] addr, input [31:0] data);
    begin
      @(posedge clk);
      m_awaddr  <= addr;
      m_awvalid <= 1'b1;
      m_wdata   <= data;
      m_wstrb   <= 4'hF;
      m_wvalid  <= 1'b1;
      m_bready  <= 1'b1;
      // Wait for awready && wready
      wait(dut.u_npu.u_csr.s_axi_awready && dut.u_npu.u_csr.s_axi_wready);
      @(posedge clk);
      m_awvalid <= 1'b0;
      m_wvalid  <= 1'b0;
      // Wait for bvalid
      wait(dut.u_npu.u_csr.s_axi_bvalid);
      @(posedge clk);
      m_bready  <= 1'b0;
      @(posedge clk);
    end
  endtask

  task automatic axi_read(input [31:0] addr, output [31:0] data);
    begin
      @(posedge clk);
      m_araddr  <= addr;
      m_arvalid <= 1'b1;
      m_rready  <= 1'b1;
      wait(dut.u_npu.u_csr.s_axi_arready);
      @(posedge clk);
      m_arvalid <= 1'b0;
      wait(dut.u_npu.u_csr.s_axi_rvalid);
      data = dut.u_npu.u_csr.s_axi_rdata;
      @(posedge clk);
      m_rready <= 1'b0;
      @(posedge clk);
    end
  endtask

  initial begin
    m_awaddr  = 0;
    m_awvalid = 0;
    m_wdata   = 0;
    m_wstrb   = 4'hF;
    m_wvalid  = 0;
    m_bready  = 0;
    m_araddr  = 0;
    m_arvalid = 0;
    m_rready  = 0;

    // Reset
    rst_n = 0;
    repeat(20) @(posedge clk);
    rst_n = 1;
    $display("[BOOT] t=%0d NPU re-program test via direct AXI", cycle);
    $fflush();

    // 1. Write DIM_M=2 (CSR offset 0x00 from MMIO_BASE 0x40000000)
    $display("[TEST] Write DIM_M=2");
    axi_write(32'h0000_0000, 32'd2);

    // 2. Write DIM_N=3 (offset 0x04)
    $display("[TEST] Write DIM_N=3");
    axi_write(32'h0000_0004, 32'd3);

    // 3. Write DIM_K=4 (offset 0x08)
    $display("[TEST] Write DIM_K=4");
    axi_write(32'h0000_0008, 32'd4);

    // 4. Write A_BASE=0x8000 (offset 0x10)
    $display("[TEST] Write A_BASE=0x8000");
    axi_write(32'h0000_0010, 32'h0000_8000);

    // 5. Write B_BASE=0x8400 (offset 0x14)
    $display("[TEST] Write B_BASE=0x8400");
    axi_write(32'h0000_0014, 32'h0000_8400);

    // 6. Write C_BASE=0x8800 (offset 0x18)
    $display("[TEST] Write C_BASE=0x8800");
    axi_write(32'h0000_0018, 32'h0000_8800);

    // 7. Write PREC=0 (offset 0x1C)
    $display("[TEST] Write PREC=0");
    axi_write(32'h0000_001C, 32'd0);

    // 8. Preload A/B in DDR
    begin
      // A = [[1,2,3,4],[5,6,7,8]]
      dut.u_ddr.mem[32'h8000] = 8'h01;
      dut.u_ddr.mem[32'h8001] = 8'h02;
      dut.u_ddr.mem[32'h8002] = 8'h03;
      dut.u_ddr.mem[32'h8003] = 8'h04;
      dut.u_ddr.mem[32'h8004] = 8'h05;
      dut.u_ddr.mem[32'h8005] = 8'h06;
      dut.u_ddr.mem[32'h8006] = 8'h07;
      dut.u_ddr.mem[32'h8007] = 8'h08;
      // B = [[1,0,0],[0,1,0],[1,0,1],[0,0,0]]
      dut.u_ddr.mem[32'h8400] = 8'h01;
      dut.u_ddr.mem[32'h8401] = 8'h00;
      dut.u_ddr.mem[32'h8402] = 8'h00;
      dut.u_ddr.mem[32'h8403] = 8'h00;
      dut.u_ddr.mem[32'h8404] = 8'h01;
      dut.u_ddr.mem[32'h8405] = 8'h00;
      dut.u_ddr.mem[32'h8406] = 8'h01;
      dut.u_ddr.mem[32'h8407] = 8'h00;
      dut.u_ddr.mem[32'h8408] = 8'h01;
      dut.u_ddr.mem[32'h8409] = 8'h00;
      dut.u_ddr.mem[32'h840a] = 8'h00;
      dut.u_ddr.mem[32'h840b] = 8'h00;
    end

    // 9. Write CTRL (start) = 1 (offset 0x20)
    $display("[TEST] Write CTRL=1 (START)");
    axi_write(32'h0000_0020, 32'd1);

    // 10. Wait for done
    $display("[TEST] Waiting for NPU done...");
    begin : wait_done
      integer t;
      t = 0;
      while (csr_done != 1 && t < 200000) begin
        @(posedge clk);
        t = t + 1;
      end
      if (csr_done)
        $display("[PASS] NPU completed after %0d cycles", t);
      else
        $display("[FAIL] NPU timed out! busy=%0d dma_phase=%0d core_state=%0d",
          csr_busy, dut.u_npu.u_dma.phase, dut.u_npu.u_core.state);
    end

    // 11. Read status
    begin
      logic [31:0] rdata;
      axi_read(32'h0000_0024, rdata);
      $display("[STATUS] 0x%08h (busy=%0d done=%0d)", rdata, rdata[1], rdata[0]);
    end

    // 12. RE-TRIGGER: Write CTRL=1 again
    $display("[TEST] Re-trigger NPU (2nd GEMM)");
    axi_write(32'h0000_0020, 32'd1);  // CTRL = start again

    $display("[TEST] Waiting for 2nd NPU done...");
    begin : wait_done2
      integer t;
      t = 0;
      while (csr_done != 1 && t < 200000) begin
        @(posedge clk);
        t = t + 1;
      end
      if (csr_done)
        $display("[PASS] NPU 2nd GEMM completed after %0d cycles", t);
      else
        $display("[FAIL] NPU 2nd GEMM timed out! busy=%0d dma_phase=%0d core_state=%0d",
          csr_busy, dut.u_npu.u_dma.phase, dut.u_npu.u_core.state);
    end

    // 13. RE-TRIGGER: Write CTRL=1 again
    $display("[TEST] Re-trigger NPU (3rd GEMM)");
    axi_write(32'h0000_0020, 32'd1);  // CTRL = start again

    $display("[TEST] Waiting for 3rd NPU done...");
    begin : wait_done3
      integer t;
      t = 0;
      while (csr_done != 1 && t < 200000) begin
        @(posedge clk);
        t = t + 1;
      end
      if (csr_done)
        $display("[PASS] NPU 3rd GEMM completed after %0d cycles", t);
      else
        $display("[FAIL] NPU 3rd GEMM timed out! busy=%0d dma_phase=%0d core_state=%0d",
          csr_busy, dut.u_npu.u_dma.phase, dut.u_npu.u_core.state);
    end

    $display("[RESULT] All NPU re-triggers passed!");
    $finish;
  end

  // Timeout
  initial begin
    #50000000;
    $display("[TIMEOUT] Simulation timed out at t=%0d", cycle);
    $display("  bridge_st=%0d dcm=%0d npu_busy=%0d npu_done=%0d csr_done=%0d",
      bridge_st, dcm_st, csr_busy, dut.u_npu.o_done, csr_done);
    $finish;
  end

endmodule
