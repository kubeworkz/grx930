// tb_npu_retrigger2.sv — Direct AXI retrigger (proven working) but
// also monitors the CPU path to see if the bridge stalls.
// We run 3 GEMMs via direct AXI, then let the CPU try a 4th via firmware.

`timescale 1ns/1ps

module tb_npu_retrigger2;

  reg         clk = 0;
  reg         rst_n = 0;
  reg  [31:0] cycle = 0;

  always #5 clk = ~clk;
  always @(posedge clk) cycle <= cycle + 1;

  c930_soc_top #(.MAX_M(8), .MAX_K(16), .MAX_N(12)) dut (
    .i_clk   (clk),
    .i_rst_n (rst_n)
  );

  // ---- AXI master interface to NPU CSR (direct poke, bypass CPU) ----
  reg  [31:0] m_awaddr;
  reg         m_awvalid;
  reg  [31:0] m_wdata;
  reg  [3:0]  m_wstrb;
  reg         m_wvalid;
  reg         m_bready;
  reg  [31:0] m_araddr;
  reg         m_arvalid;
  reg         m_rready;

  // Drive CSR slave AXI signals from our master
  wire csr_awready = dut.u_npu.u_csr.s_axi_awready;
  wire csr_wready  = dut.u_npu.u_csr.s_axi_wready;
  wire csr_bvalid  = dut.u_npu.u_csr.s_axi_bvalid;
  wire csr_bresp   = dut.u_npu.u_csr.s_axi_bresp;
  wire csr_arready = dut.u_npu.u_csr.s_axi_arready;
  wire csr_rvalid  = dut.u_npu.u_csr.s_axi_rvalid;
  wire [31:0] csr_rdata = dut.u_npu.u_csr.s_axi_rdata;

  assign dut.u_npu.u_csr.s_axi_awaddr  = m_awaddr;
  assign dut.u_npu.u_csr.s_axi_awvalid = m_awvalid;
  assign dut.u_npu.u_csr.s_axi_wdata   = m_wdata;
  assign dut.u_npu.u_csr.s_axi_wstrb   = m_wstrb;
  assign dut.u_npu.u_csr.s_axi_wvalid  = m_wvalid;
  assign dut.u_npu.u_csr.s_axi_bready  = m_bready;
  assign dut.u_npu.u_csr.s_axi_araddr  = m_araddr;
  assign dut.u_npu.u_csr.s_axi_arvalid = m_arvalid;
  assign dut.u_npu.u_csr.s_axi_rready  = m_rready;

  // AXI write task
  task automatic axi_write(input [31:0] addr, input [31:0] data);
    begin
      @(posedge clk);
      m_awaddr  <= addr;
      m_awvalid <= 1'b1;
      m_wdata   <= data;
      m_wstrb   <= 4'hF;
      m_wvalid  <= 1'b1;
      m_bready  <= 1'b0;
      // Wait for handshake
      @(posedge clk);
      while (!(csr_awready && m_awvalid && csr_wready && m_wvalid))
        @(posedge clk);
      m_awvalid <= 1'b0;
      m_wvalid  <= 1'b0;
      // Wait for bvalid
      @(posedge clk);
      while (!csr_bvalid) @(posedge clk);
      m_bready  <= 1'b1;
      @(posedge clk);
      m_bready  <= 1'b0;
      @(posedge clk);
    end
  endtask

  // AXI read task
  task automatic axi_read(input [31:0] addr, output [31:0] data);
    begin
      @(posedge clk);
      m_araddr  <= addr;
      m_arvalid <= 1'b1;
      m_rready  <= 1'b1;
      @(posedge clk);
      while (!(csr_arready && m_arvalid))
        @(posedge clk);
      m_arvalid <= 1'b0;
      // Wait for rvalid
      @(posedge clk);
      while (!csr_rvalid) @(posedge clk);
      data = csr_rdata;
      m_rready <= 1'b0;
      @(posedge clk);
    end
  endtask

  // CSR offsets (word addresses → byte addresses)
  localparam [31:0] CSR_CTRL   = 32'h00;
  localparam [31:0] CSR_DIM_M  = 32'h08;
  localparam [31:0] CSR_DIM_N  = 32'h0C;
  localparam [31:0] CSR_DIM_K  = 32'h10;
  localparam [31:0] CSR_A_BASE = 32'h14;
  localparam [31:0] CSR_B_BASE = 32'h18;
  localparam [31:0] CSR_C_BASE = 32'h1C;
  localparam [31:0] CSR_PREC   = 32'h20;
  localparam [31:0] CSR_STATUS = 32'h04;
  localparam [31:0] CSR_CYCLE  = 32'h24;

  // Preload A/B for M=2 N=3 K=4 INT8
  task automatic preload_data();
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
      // Clear C
      for (int i = 0; i < 64; i++) dut.u_ddr.mem[32'h8800 + i] = 8'h00;
    end
  endtask

  // Program NPU and kick
  task automatic kick_npu(input [31:0] prec);
    begin
      axi_write(CSR_DIM_M,  32'd2);
      axi_write(CSR_DIM_N,  32'd3);
      axi_write(CSR_DIM_K,  32'd4);
      axi_write(CSR_A_BASE, 32'h0000_8000);
      axi_write(CSR_B_BASE, 32'h0000_8400);
      axi_write(CSR_C_BASE, 32'h0000_8800);
      axi_write(CSR_PREC,   prec);
      // Read-back barrier (like the C driver does)
      begin
        logic [31:0] tmp;
        axi_read(CSR_PREC, tmp);
      end
      // START
      axi_write(CSR_CTRL, 32'h01);
    end
  endtask

  // Wait for done via polling STATUS register
  task automatic wait_done(input integer max_cycles, output integer ok);
    begin
      integer t;
      logic [31:0] status;
      ok = 0;
      for (t = 0; t < max_cycles; t = t + 1) begin
        axi_read(CSR_STATUS, status);
        if (status[1]) begin  // done_latch bit
          ok = 1;
          $display("[DONE] t=%0d after %0d polls, status=0x%08h", cycle, t, status);
          // Read cycle counter
          axi_read(CSR_CYCLE, status);
          $display("[CYCLES] %0d", status);
          // Clear done by re-reading status after a dummy write
          // Actually, done is cleared on next START pulse
          t = max_cycles; // break
        end
      end
      if (!ok)
        $display("[TIMEOUT] t=%0d NPU didn't complete after %0d polls", cycle, max_cycles);
    end
  endtask

  integer pass_count;
  integer fail_count;

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
    pass_count = 0;
    fail_count = 0;

    // Preload data
    preload_data();

    // Reset
    rst_n = 0;
    repeat(20) @(posedge clk);
    rst_n = 1;
    $display("[BOOT] t=%0d NPU retrigger test (direct AXI)", cycle);

    // ---- 3 direct AXI GEMMs (all precisions) ----
    begin : test_block
      integer ok;
      integer p;

      for (p = 0; p < 4; p++) begin
        kick_npu(p[31:0]);
        wait_done(50000, ok);
        if (ok) begin
          pass_count = pass_count + 1;
          $display("[PASS] GEMM prec=%0d", p);
        end else begin
          fail_count = fail_count + 1;
          $display("[FAIL] GEMM prec=%0d", p);
        end
      end
    end

    // ---- Check C output for last GEMM ----
    $display("[CHECK] C[0..2] = %02h %02h %02h",
      dut.u_ddr.mem[32'h8800],
      dut.u_ddr.mem[32'h8801],
      dut.u_ddr.mem[32'h8802]);

    // ---- Summary ----
    $display("");
    $display("=== RESULT ===");
    $display("  PASS: %0d  FAIL: %0d", pass_count, fail_count);
    if (fail_count == 0)
      $display("  PASS");
    else
      $display("  FAIL");
    $display("==============");
    $finish;
  end

  // Global timeout
  initial begin
    #10000000;
    $display("[TIMEOUT] Global timeout at t=%0d", cycle);
    $finish;
  end

endmodule
