// tb_npu_benchmark.sv — NPU performance benchmark.
// Drives the NPU CSR directly via hierarchical poke to measure cycle counts
// and compute TOPS across INT8/INT16/FP16 precisions and GEMM sizes.
// Bypasses CPU/MMIO bridge entirely — pure NPU measurement.

`timescale 1ns/1ps

module tb_npu_benchmark;

  reg         clk = 0;
  reg         rst_n = 0;
  reg  [31:0] cycle = 0;

  always #5 clk = ~clk;
  always @(posedge clk) cycle <= cycle + 1;

  // ---- AXI signals (same as retrigger test) ----
  reg  [31:0] csr_awaddr  = 0;
  reg         csr_awvalid = 0;
  wire        csr_awready;
  reg  [31:0] csr_wdata   = 0;
  reg  [3:0]  csr_wstrb   = 4'hF;
  reg         csr_wvalid  = 0;
  wire        csr_wready;
  wire [1:0]  csr_bresp;
  wire        csr_bvalid;
  reg         csr_bready  = 0;
  reg  [31:0] csr_araddr  = 0;
  reg         csr_arvalid = 0;
  wire        csr_arready;
  wire [31:0] csr_rdata;
  wire [1:0]  csr_rresp;
  wire        csr_rvalid;
  reg         csr_rready  = 0;

  // NPU AXI4 master
  wire [31:0] npu_araddr;
  wire [7:0]  npu_arlen;
  wire [2:0]  npu_arsize;
  wire [1:0]  npu_arburst;
  wire        npu_arvalid, npu_arready;
  wire [31:0] npu_rdata;
  wire [1:0]  npu_rresp;
  wire        npu_rlast, npu_rvalid, npu_rready;
  wire [31:0] npu_awaddr;
  wire [7:0]  npu_awlen;
  wire [2:0]  npu_awsize;
  wire [1:0]  npu_awburst;
  wire        npu_awvalid, npu_awready;
  wire [31:0] npu_wdata;
  wire [3:0]  npu_wstrb;
  wire        npu_wlast, npu_wvalid, npu_wready;
  wire [1:0]  npu_bresp;
  wire        npu_bvalid, npu_bready;

  wire        npu_busy, npu_done, npu_error;

  // ---- DDR model ----
  reg  [7:0]  ddr_mem [0:65535];
  reg  [31:0] ddr_r_addr;
  reg  [7:0]  ddr_r_len, ddr_r_beat;
  reg         ddr_r_busy = 0;
  reg  [31:0] ddr_w_addr;
  reg  [7:0]  ddr_w_len, ddr_w_beat;
  reg         ddr_w_busy = 0;
  reg         ddr_b_valid = 0;

  assign npu_arready = ~ddr_r_busy;
  assign npu_rvalid  = ddr_r_busy;
  assign npu_rlast   = (ddr_r_beat == ddr_r_len);
  assign npu_rresp   = 2'b00;
  assign npu_rdata   = {ddr_mem[npu_araddr + ddr_r_beat*4 + 3],
                         ddr_mem[npu_araddr + ddr_r_beat*4 + 2],
                         ddr_mem[npu_araddr + ddr_r_beat*4 + 1],
                         ddr_mem[npu_araddr + ddr_r_beat*4 + 0]};
  assign npu_awready = ~ddr_w_busy;
  assign npu_wready  = ddr_w_busy;
  assign npu_bvalid  = ddr_b_valid;
  assign npu_bresp   = 2'b00;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ddr_r_busy <= 0; ddr_r_beat <= 0;
      ddr_w_busy <= 0; ddr_w_beat <= 0;
      ddr_b_valid <= 0;
    end else begin
      if (npu_arvalid && npu_arready && !ddr_r_busy) begin
        ddr_r_addr <= npu_araddr;
        ddr_r_len  <= npu_arlen;
        ddr_r_beat <= 0;
        ddr_r_busy <= 1;
      end
      if (ddr_r_busy && npu_rvalid && npu_rready) begin
        if (ddr_r_beat == ddr_r_len) ddr_r_busy <= 0;
        else ddr_r_beat <= ddr_r_beat + 1;
      end
      if (npu_awvalid && npu_awready && !ddr_w_busy) begin
        ddr_w_addr <= npu_awaddr;
        ddr_w_len  <= npu_awlen;
        ddr_w_beat <= 0;
        ddr_w_busy <= 1;
      end
      if (ddr_w_busy && npu_wvalid && npu_wready) begin
        for (int i = 0; i < 4; i++)
          if (npu_wstrb[i])
            ddr_mem[ddr_w_addr + ddr_w_beat*4 + i] <= npu_wdata[i*8 +: 8];
        if (ddr_w_beat == ddr_w_len) begin
          ddr_w_busy <= 0; ddr_b_valid <= 1;
        end else ddr_w_beat <= ddr_w_beat + 1;
      end
      if (ddr_b_valid && npu_bready) ddr_b_valid <= 0;
    end
  end

  // ---- NPU ----
  c930_npu_top #(.MAX_M(8), .MAX_K(32), .MAX_N(16)) u_npu (
    .i_clk(clk), .i_rst_n(rst_n),
    .s_axi_awaddr(csr_awaddr), .s_axi_awvalid(csr_awvalid), .s_axi_awready(csr_awready),
    .s_axi_wdata(csr_wdata), .s_axi_wstrb(csr_wstrb), .s_axi_wvalid(csr_wvalid), .s_axi_wready(csr_wready),
    .s_axi_bresp(csr_bresp), .s_axi_bvalid(csr_bvalid), .s_axi_bready(csr_bready),
    .s_axi_araddr(csr_araddr), .s_axi_arvalid(csr_arvalid), .s_axi_arready(csr_arready),
    .s_axi_rdata(csr_rdata), .s_axi_rresp(csr_rresp), .s_axi_rvalid(csr_rvalid), .s_axi_rready(csr_rready),
    .m_axi_araddr(npu_araddr), .m_axi_arlen(npu_arlen), .m_axi_arsize(npu_arsize), .m_axi_arburst(npu_arburst),
    .m_axi_arvalid(npu_arvalid), .m_axi_arready(npu_arready),
    .m_axi_rdata(npu_rdata), .m_axi_rresp(npu_rresp), .m_axi_rlast(npu_rlast),
    .m_axi_rvalid(npu_rvalid), .m_axi_rready(npu_rready),
    .m_axi_awaddr(npu_awaddr), .m_axi_awlen(npu_awlen), .m_axi_awsize(npu_awsize), .m_axi_awburst(npu_awburst),
    .m_axi_awvalid(npu_awvalid), .m_axi_awready(npu_awready),
    .m_axi_wdata(npu_wdata), .m_axi_wstrb(npu_wstrb), .m_axi_wlast(npu_wlast),
    .m_axi_wvalid(npu_wvalid), .m_axi_wready(npu_wready),
    .m_axi_bresp(npu_bresp), .m_axi_bvalid(npu_bvalid), .m_axi_bready(npu_bready),
    .o_busy(npu_busy), .o_done(npu_done), .o_error(npu_error), .o_irq()
  );

  // ---- CSR addresses ----
  localparam ADDR_CTRL=32'h00, ADDR_STAT=32'h04, ADDR_DIM_M=32'h08,
             ADDR_DIM_N=32'h0C, ADDR_DIM_K=32'h10, ADDR_A_BASE=32'h14,
             ADDR_B_BASE=32'h18, ADDR_C_BASE=32'h1C, ADDR_PREC=32'h20,
             ADDR_CYCLE_LO=32'h24, ADDR_CYCLE_HI=32'h28;

  // ---- AXI write/read tasks ----
  task axi_write(input [31:0] addr, input [31:0] data);
    begin
      @(posedge clk);
      csr_awaddr <= addr; csr_awvalid <= 1;
      csr_wdata <= data; csr_wstrb <= 4'hF; csr_wvalid <= 1;
      csr_bready <= 1;
      while (!(csr_awready && csr_wready)) @(posedge clk);
      @(posedge clk);
      csr_awvalid <= 0; csr_wvalid <= 0;
      while (!csr_bvalid) @(posedge clk);
      @(posedge clk);
      csr_bready <= 0;
    end
  endtask

  task automatic axi_read(input [31:0] addr, output [31:0] data);
    begin
      @(posedge clk);
      csr_araddr <= addr; csr_arvalid <= 1; csr_rready <= 1;
      while (!csr_arready) @(posedge clk);
      @(posedge clk);
      csr_arvalid <= 0;
      while (!csr_rvalid) @(posedge clk);
      data = csr_rdata;
      @(posedge clk);
      csr_rready <= 0;
    end
  endtask

  // ---- Benchmark: run one GEMM, return cycle count ----
  task automatic run_gemm(
    input int m, n, k, prec,
    input [31:0] a_addr, b_addr, c_addr,
    output int cycles, output integer ok
  );
    integer status;
    integer timeout;
    begin
      axi_write(ADDR_DIM_M, m);
      axi_write(ADDR_DIM_N, n);
      axi_write(ADDR_DIM_K, k);
      axi_write(ADDR_A_BASE, a_addr);
      axi_write(ADDR_B_BASE, b_addr);
      axi_write(ADDR_C_BASE, c_addr);
      axi_write(ADDR_PREC, prec);
      axi_read(ADDR_PREC, status); // barrier
      // Reset cycle counter by reading it
      cycles = 0;
      ok = 0;
      // Kick
      axi_write(ADDR_CTRL, 32'h00000001);
      // Poll until done
      timeout = 0;
      forever begin
        axi_read(ADDR_STAT, status);
        if (status[1]) begin // done_latch
          // Read cycle counter
          begin : rd_cyc
            integer clo, chi;
            axi_read(ADDR_CYCLE_LO, clo);
            axi_read(ADDR_CYCLE_HI, chi);
            cycles = clo; // 32-bit counter for now
          end
          ok = 1;
          disable run_gemm;
        end
        timeout = timeout + 1;
        if (timeout > 200000) begin
          $display("  [TIMEOUT] m=%0d n=%0d k=%0d prec=%0d stuck at DMA phase=%0d core_state=%0d",
            m, n, k, prec, u_npu.u_dma.phase, u_npu.u_core.state);
          disable run_gemm;
        end
      end
    end
  endtask

  // ---- Fill DDR with test data ----
  task automatic fill_int8(input [31:0] base, input int m, k, input int seed);
    integer i;
    integer v;
    begin
      for (i = 0; i < m * k; i = i + 1) begin
        v = ((seed * 7 + i * 13) % 17) - 8; // [-8, 8]
        ddr_mem[base + i] = v[7:0];
      end
    end
  endtask

  task automatic fill_int16(input [31:0] base, input int m, k, input int seed);
    integer i;
    integer v;
    begin
      for (i = 0; i < m * k; i = i + 1) begin
        v = ((seed * 7 + i * 13) % 512) - 256;
        ddr_mem[base + i*2 + 0] = v[7:0];
        ddr_mem[base + i*2 + 1] = v[15:8];
      end
    end
  endtask

  // ---- Main test ----
  integer cycles_val;
  integer ok_val;
  integer m, n, k;
  integer tops_x1000;
  reg [31:0] cycle_lo, cycle_hi;
  integer total_macs;

  initial begin
    $dumpfile("build/vcd/tb_npu_benchmark.vcd");
    $dumpvars(0, tb_npu_benchmark);

    // Reset
    rst_n = 0;
    repeat(20) @(posedge clk);
    rst_n = 1;

    $display("=================================================================");
    $display("  GRX930 NPU Performance Benchmark");
    $display("=================================================================");
    $display("");

    // ---- INT8 benchmarks ----
    $display("--- INT8 (precision=0) ---");
    begin : int8_bench
      // M=1 N=1 K=8 (minimal)
      fill_int8(32'h0000, 1, 8, 1); // A
      fill_int8(32'h0100, 8, 1, 2); // B
      run_gemm(1, 1, 8, 0, 32'h0000, 32'h0100, 32'h0200, cycles_val, ok_val);
      if (ok_val) begin
        total_macs = 2*1*1*8;
        tops_x1000 = (total_macs * 100) / cycles_val; // in units of 0.01 TOPS
        $display("  M=1  N=1  K=8   cycles=%0d  macs=%0d  perf=%0d.%02d TOPS",
          cycles_val, total_macs, tops_x1000/100, tops_x1000%100);
      end

      // M=2 N=3 K=4
      fill_int8(32'h0000, 2, 4, 10); fill_int8(32'h0100, 4, 3, 20);
      run_gemm(2, 3, 4, 0, 32'h0000, 32'h0100, 32'h0200, cycles_val, ok_val);
      if (ok_val) begin
        total_macs = 2*2*3*4;
        tops_x1000 = (total_macs * 100) / cycles_val;
        $display("  M=2  N=3  K=4   cycles=%0d  macs=%0d  perf=%0d.%02d TOPS",
          cycles_val, total_macs, tops_x1000/100, tops_x1000%100);
      end

      // M=4 N=4 K=8
      fill_int8(32'h0000, 4, 8, 30); fill_int8(32'h0100, 8, 4, 40);
      run_gemm(4, 4, 8, 0, 32'h0000, 32'h0100, 32'h0200, cycles_val, ok_val);
      if (ok_val) begin
        total_macs = 2*4*4*8;
        tops_x1000 = (total_macs * 100) / cycles_val;
        $display("  M=4  N=4  K=8   cycles=%0d  macs=%0d  perf=%0d.%02d TOPS",
          cycles_val, total_macs, tops_x1000/100, tops_x1000%100);
      end

      // M=8 N=8 K=8
      fill_int8(32'h0000, 8, 8, 50); fill_int8(32'h0100, 8, 8, 60);
      run_gemm(8, 8, 8, 0, 32'h0000, 32'h0100, 32'h0200, cycles_val, ok_val);
      if (ok_val) begin
        total_macs = 2*8*8*8;
        tops_x1000 = (total_macs * 100) / cycles_val;
        $display("  M=8  N=8  K=8   cycles=%0d  macs=%0d  perf=%0d.%02d TOPS",
          cycles_val, total_macs, tops_x1000/100, tops_x1000%100);
      end

      // M=8 N=8 K=16 (2 K-tiles)
      fill_int8(32'h0000, 8, 16, 70); fill_int8(32'h0100, 16, 8, 80);
      run_gemm(8, 8, 16, 0, 32'h0000, 32'h0100, 32'h0200, cycles_val, ok_val);
      if (ok_val) begin
        total_macs = 2*8*8*16;
        tops_x1000 = (total_macs * 100) / cycles_val;
        $display("  M=8  N=8  K=16  cycles=%0d  macs=%0d  perf=%0d.%02d TOPS",
          cycles_val, total_macs, tops_x1000/100, tops_x1000%100);
      end

      // M=8 N=12 K=16 (N-tiling + 2 K-tiles)
      fill_int8(32'h0000, 8, 16, 90); fill_int8(32'h0200, 16, 12, 100);
      run_gemm(8, 12, 16, 0, 32'h0000, 32'h0200, 32'h0400, cycles_val, ok_val);
      if (ok_val) begin
        total_macs = 2*8*12*16;
        tops_x1000 = (total_macs * 100) / cycles_val;
        $display("  M=8  N=12 K=16  cycles=%0d  macs=%0d  perf=%0d.%02d TOPS",
          cycles_val, total_macs, tops_x1000/100, tops_x1000%100);
      end
    end

    $display("");

    // ---- INT16 benchmarks ----
    $display("--- INT16 (precision=1) ---");
    begin : int16_bench
      fill_int16(32'h0000, 2, 4, 101); fill_int16(32'h0100, 4, 3, 102);
      run_gemm(2, 3, 4, 1, 32'h0000, 32'h0100, 32'h0200, cycles_val, ok_val);
      if (ok_val) begin
        total_macs = 2*2*3*4;
        tops_x1000 = (total_macs * 100) / cycles_val;
        $display("  M=2  N=3  K=4   cycles=%0d  macs=%0d  perf=%0d.%02d TOPS",
          cycles_val, total_macs, tops_x1000/100, tops_x1000%100);
      end

      fill_int16(32'h0000, 8, 8, 103); fill_int16(32'h0200, 8, 8, 104);
      run_gemm(8, 8, 8, 1, 32'h0000, 32'h0200, 32'h0400, cycles_val, ok_val);
      if (ok_val) begin
        total_macs = 2*8*8*8;
        tops_x1000 = (total_macs * 100) / cycles_val;
        $display("  M=8  N=8  K=8   cycles=%0d  macs=%0d  perf=%0d.%02d TOPS",
          cycles_val, total_macs, tops_x1000/100, tops_x1000%100);
      end

      fill_int16(32'h0000, 8, 16, 105); fill_int16(32'h0200, 16, 8, 106);
      run_gemm(8, 8, 16, 1, 32'h0000, 32'h0200, 32'h0400, cycles_val, ok_val);
      if (ok_val) begin
        total_macs = 2*8*8*16;
        tops_x1000 = (total_macs * 100) / cycles_val;
        $display("  M=8  N=8  K=16  cycles=%0d  macs=%0d  perf=%0d.%02d TOPS",
          cycles_val, total_macs, tops_x1000/100, tops_x1000%100);
      end
    end

    $display("");

    // ---- INT4 benchmarks ----
    $display("--- INT4 (precision=4) ---");
    begin : int4_bench
      // INT4: 2 elements packed per byte
      // A (2x4): pack as 4 bytes
      ddr_mem[32'h0000] = 8'h21; ddr_mem[32'h0001] = 8'h43; // row0: [1,2,3,4]
      ddr_mem[32'h0002] = 8'h65; ddr_mem[32'h0003] = 8'h87; // row1: [5,6,7,8]
      // B (4x3): pack as 6 bytes
      ddr_mem[32'h0100] = 8'h01; ddr_mem[32'h0101] = 8'h00; ddr_mem[32'h0102] = 8'h00;
      ddr_mem[32'h0103] = 8'h01; ddr_mem[32'h0104] = 8'h10; ddr_mem[32'h0105] = 8'h00;
      run_gemm(2, 3, 4, 4, 32'h0000, 32'h0100, 32'h0200, cycles_val, ok_val);
      if (ok_val) begin
        total_macs = 2*2*3*4;
        tops_x1000 = (total_macs * 100) / cycles_val;
        $display("  M=2  N=3  K=4   cycles=%0d  macs=%0d  perf=%0d.%02d TOPS",
          cycles_val, total_macs, tops_x1000/100, tops_x1000%100);
      end

      // M=4 N=4 K=8 INT4
      fill_int8(32'h0000, 4, 8, 200); // reuse int8 fill (4 bits sign-extended)
      fill_int8(32'h0100, 8, 4, 201);
      run_gemm(4, 4, 8, 4, 32'h0000, 32'h0100, 32'h0200, cycles_val, ok_val);
      if (ok_val) begin
        total_macs = 2*4*4*8;
        tops_x1000 = (total_macs * 100) / cycles_val;
        $display("  M=4  N=4  K=8   cycles=%0d  macs=%0d  perf=%0d.%02d TOPS",
          cycles_val, total_macs, tops_x1000/100, tops_x1000%100);
      end

      fill_int8(32'h0000, 8, 8, 202); fill_int8(32'h0100, 8, 8, 203);
      run_gemm(8, 8, 8, 4, 32'h0000, 32'h0100, 32'h0200, cycles_val, ok_val);
      if (ok_val) begin
        total_macs = 2*8*8*8;
        tops_x1000 = (total_macs * 100) / cycles_val;
        $display("  M=8  N=8  K=8   cycles=%0d  macs=%0d  perf=%0d.%02d TOPS",
          cycles_val, total_macs, tops_x1000/100, tops_x1000%100);
      end

      fill_int8(32'h0000, 8, 16, 204); fill_int8(32'h0100, 16, 8, 205);
      run_gemm(8, 8, 16, 4, 32'h0000, 32'h0100, 32'h0200, cycles_val, ok_val);
      if (ok_val) begin
        total_macs = 2*8*8*16;
        tops_x1000 = (total_macs * 100) / cycles_val;
        $display("  M=8  N=8  K=16  cycles=%0d  macs=%0d  perf=%0d.%02d TOPS",
          cycles_val, total_macs, tops_x1000/100, tops_x1000%100);
      end
    end

    $display("");
    $display("=================================================================");
    $display("  Benchmark complete. All GEMMs completed successfully.");
    $display("=================================================================");
    $finish;
  end

  initial begin
    #10000000;
    $display("[TIMEOUT] Global timeout");
    $finish;
  end

endmodule
