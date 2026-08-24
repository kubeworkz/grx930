// tb_npu_retrigger.sv — Direct NPU re-trigger test.
// Drives the NPU's AXI4-Lite CSR port directly (no CPU) to test
// whether the NPU can complete back-to-back GEMMs.
// This isolates the NPU from the CPU/dcache/MMIO bridge stack.

`timescale 1ns/1ps

module tb_npu_retrigger;

  reg         clk = 0;
  reg         rst_n = 0;
  reg  [31:0] cycle = 0;

  always #5 clk = ~clk; // 100 MHz
  always @(posedge clk) cycle <= cycle + 1;

  // ---- NPU AXI4-Lite CSR signals ----
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

  // ---- NPU AXI4 master (to DDR) ----
  wire [31:0] npu_araddr;
  wire [7:0]  npu_arlen;
  wire [2:0]  npu_arsize;
  wire [1:0]  npu_arburst;
  wire        npu_arvalid;
  wire        npu_arready;
  wire [31:0] npu_rdata;
  wire [1:0]  npu_rresp;
  wire        npu_rlast;
  wire        npu_rvalid;
  wire        npu_rready;
  wire [31:0] npu_awaddr;
  wire [7:0]  npu_awlen;
  wire [2:0]  npu_awsize;
  wire [1:0]  npu_awburst;
  wire        npu_awvalid;
  wire        npu_awready;
  wire [31:0] npu_wdata;
  wire [3:0]  npu_wstrb;
  wire        npu_wlast;
  wire        npu_wvalid;
  wire        npu_wready;
  wire [1:0]  npu_bresp;
  wire        npu_bvalid;
  wire        npu_bready;

  wire        npu_busy;
  wire        npu_done;
  wire        npu_error;

  // ---- DDR model (minimal: byte array) ----
  reg  [7:0]  ddr_mem [0:65535];
  // AXI slave for NPU
  reg  [31:0] ddr_r_addr;
  reg  [7:0]  ddr_r_len;
  reg  [7:0]  ddr_r_beat;
  reg         ddr_r_busy = 0;
  reg  [31:0] ddr_w_addr;
  reg  [7:0]  ddr_w_len;
  reg  [7:0]  ddr_w_beat;
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
        if (ddr_r_beat == ddr_r_len)
          ddr_r_busy <= 0;
        else
          ddr_r_beat <= ddr_r_beat + 1;
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
          ddr_w_busy <= 0;
          ddr_b_valid <= 1;
        end else
          ddr_w_beat <= ddr_w_beat + 1;
      end
      if (ddr_b_valid && npu_bready)
        ddr_b_valid <= 0;
    end
  end

  // ---- NPU top ----
  c930_npu_top #(
    .MAX_M(8), .MAX_K(16), .MAX_N(12)
  ) u_npu (
    .i_clk      (clk),
    .i_rst_n    (rst_n),
    .s_axi_awaddr  (csr_awaddr),
    .s_axi_awvalid (csr_awvalid),
    .s_axi_awready (csr_awready),
    .s_axi_wdata   (csr_wdata),
    .s_axi_wstrb   (csr_wstrb),
    .s_axi_wvalid  (csr_wvalid),
    .s_axi_wready  (csr_wready),
    .s_axi_bresp   (csr_bresp),
    .s_axi_bvalid  (csr_bvalid),
    .s_axi_bready  (csr_bready),
    .s_axi_araddr  (csr_araddr),
    .s_axi_arvalid (csr_arvalid),
    .s_axi_arready (csr_arready),
    .s_axi_rdata   (csr_rdata),
    .s_axi_rresp   (csr_rresp),
    .s_axi_rvalid  (csr_rvalid),
    .s_axi_rready  (csr_rready),
    .m_axi_araddr  (npu_araddr),
    .m_axi_arlen   (npu_arlen),
    .m_axi_arsize  (npu_arsize),
    .m_axi_arburst (npu_arburst),
    .m_axi_arvalid (npu_arvalid),
    .m_axi_arready (npu_arready),
    .m_axi_rdata   (npu_rdata),
    .m_axi_rresp   (npu_rresp),
    .m_axi_rlast   (npu_rlast),
    .m_axi_rvalid  (npu_rvalid),
    .m_axi_rready  (npu_rready),
    .m_axi_awaddr  (npu_awaddr),
    .m_axi_awlen   (npu_awlen),
    .m_axi_awsize  (npu_awsize),
    .m_axi_awburst (npu_awburst),
    .m_axi_awvalid (npu_awvalid),
    .m_axi_awready (npu_awready),
    .m_axi_wdata   (npu_wdata),
    .m_axi_wstrb   (npu_wstrb),
    .m_axi_wlast   (npu_wlast),
    .m_axi_wvalid  (npu_wvalid),
    .m_axi_wready  (npu_wready),
    .m_axi_bresp   (npu_bresp),
    .m_axi_bvalid  (npu_bvalid),
    .m_axi_bready  (npu_bready),
    .o_busy        (npu_busy),
    .o_done        (npu_done),
    .o_error       (npu_error),
    .o_irq         ()
  );

  // ---- CSR address map ----
  localparam ADDR_CTRL   = 32'h00;
  localparam ADDR_STAT   = 32'h04;
  localparam ADDR_DIM_M  = 32'h08;
  localparam ADDR_DIM_N  = 32'h0C;
  localparam ADDR_DIM_K  = 32'h10;
  localparam ADDR_A_BASE = 32'h14;
  localparam ADDR_B_BASE = 32'h18;
  localparam ADDR_C_BASE = 32'h1C;
  localparam ADDR_PREC   = 32'h20;

  // ---- AXI write task ----
  task axi_write(input [31:0] addr, input [31:0] data);
    begin
      @(posedge clk);
      csr_awaddr  <= addr;
      csr_awvalid <= 1;
      csr_wdata   <= data;
      csr_wstrb   <= 4'hF;
      csr_wvalid  <= 1;
      csr_bready  <= 1;
      // Wait for handshake
      while (!(csr_awready && csr_wready)) @(posedge clk);
      @(posedge clk);
      csr_awvalid <= 0;
      csr_wvalid  <= 0;
      // Wait for bvalid
      while (!csr_bvalid) @(posedge clk);
      @(posedge clk);
      csr_bready <= 0;
    end
  endtask

  // ---- AXI read task ----
  task automatic axi_read(input [31:0] addr, output [31:0] data);
    begin
      @(posedge clk);
      csr_araddr  <= addr;
      csr_arvalid <= 1;
      csr_rready  <= 1;
      while (!csr_arready) @(posedge clk);
      @(posedge clk);
      csr_arvalid <= 0;
      while (!csr_rvalid) @(posedge clk);
      data = csr_rdata;
      @(posedge clk);
      csr_rready <= 0;
    end
  endtask

  // ---- Test body ----
  integer i;
  reg [31:0] status;
  integer kick_count = 0;
  integer done_count = 0;

  initial begin
    $dumpfile("build/vcd/tb_npu_retrigger.vcd");
    $dumpvars(0, tb_npu_retrigger);

    // Initialize DDR: A = [1,2,3,4,5,6,7,8], B = [1,0,0,1,0,1,1,0,0,1,0,1,1,0,1,0]
    // A (2x4): row0={1,2,3,4}, row1={5,6,7,8}
    ddr_mem[32'h0000] = 8'h01; ddr_mem[32'h0001] = 8'h02;
    ddr_mem[32'h0002] = 8'h03; ddr_mem[32'h0003] = 8'h04;
    ddr_mem[32'h0004] = 8'h05; ddr_mem[32'h0005] = 8'h06;
    ddr_mem[32'h0006] = 8'h07; ddr_mem[32'h0007] = 8'h08;
    // B (4x3): row0={1,0,0}, row1={0,1,0}, row2={1,0,1}, row3={0,0,0}
    ddr_mem[32'h0100] = 8'h01; ddr_mem[32'h0101] = 8'h00; ddr_mem[32'h0102] = 8'h00;
    ddr_mem[32'h0103] = 8'h00; ddr_mem[32'h0104] = 8'h01; ddr_mem[32'h0105] = 8'h00;
    ddr_mem[32'h0106] = 8'h01; ddr_mem[32'h0107] = 8'h00; ddr_mem[32'h0108] = 8'h01;
    ddr_mem[32'h0109] = 8'h00; ddr_mem[32'h010a] = 8'h00; ddr_mem[32'h010b] = 8'h00;

    // Reset
    rst_n = 0;
    repeat(20) @(posedge clk);
    rst_n = 1;
    $display("[BOOT] t=%0d NPU released from reset", cycle);

    // ====================================================================
    // GEMM 1: M=2 N=3 K=4 INT8 (precision=0)
    // A=[[1,2,3,4],[5,6,7,8]], B=[[1,0,0],[0,1,0],[1,0,1],[0,0,0]]
    // Expected C = [[4,2,3],[12,6,11]]
    // ====================================================================
    $display("[GEMM1] Programming NPU: M=2 N=3 K=4 prec=0");
    axi_write(ADDR_DIM_M,  32'd2);
    axi_write(ADDR_DIM_N,  32'd3);
    axi_write(ADDR_DIM_K,  32'd4);
    axi_write(ADDR_A_BASE, 32'h0000);
    axi_write(ADDR_B_BASE, 32'h0100);
    axi_write(ADDR_C_BASE, 32'h0200);
    axi_write(ADDR_PREC,   32'd0);  // INT8
    // Read-back barrier
    axi_read(ADDR_PREC, status);
    $display("[GEMM1] PREC readback = %0d", status);
    // Kick
    kick_count = kick_count + 1;
    axi_write(ADDR_CTRL, 32'h00000001); // START=1
    $display("[GEMM1] t=%0d START written, waiting for done...", cycle);

    // Poll STATUS until done
    begin : gemm1_poll
      integer timeout = 0;
      forever begin
        axi_read(ADDR_STAT, status);
        if (status[1]) begin // done_latch
          $display("[GEMM1] t=%0d DONE! status=%h", cycle, status);
          done_count = done_count + 1;
          disable gemm1_poll;
        end
        timeout = timeout + 1;
        if (timeout > 50000) begin
          $display("[GEMM1] TIMEOUT after %0d cycles! status=%h busy=%0d", timeout, status, npu_busy);
          $display("[GEMM1] DMA phase=%0d core_state=%0d launched=%0d",
            u_npu.u_dma.phase, u_npu.u_core.state, u_npu.u_dma.launched);
          $finish;
        end
      end
    end

    // Check C in DDR
    $display("[GEMM1] C[0..5] = %0d %0d %0d %0d %0d %0d (expect 4 2 3 12 6 11)",
      $signed(ddr_mem[32'h0200]), $signed(ddr_mem[32'h0201]),
      $signed(ddr_mem[32'h0202]), $signed(ddr_mem[32'h0203]),
      $signed(ddr_mem[32'h0204]), $signed(ddr_mem[32'h0205]));

    repeat(10) @(posedge clk);

    // ====================================================================
    // GEMM 2: M=2 N=3 K=4 INT8 (same dims, re-trigger!)
    // ====================================================================
    $display("[GEMM2] t=%0d Re-triggering NPU: M=2 N=3 K=4 prec=0", cycle);
    axi_write(ADDR_DIM_M,  32'd2);
    axi_write(ADDR_DIM_N,  32'd3);
    axi_write(ADDR_DIM_K,  32'd4);
    axi_write(ADDR_A_BASE, 32'h0000);
    axi_write(ADDR_B_BASE, 32'h0100);
    axi_write(ADDR_C_BASE, 32'h0200);
    axi_write(ADDR_PREC,   32'd0);
    axi_read(ADDR_PREC, status);
    kick_count = kick_count + 1;
    axi_write(ADDR_CTRL, 32'h00000001);
    $display("[GEMM2] t=%0d START written, waiting for done...", cycle);

    begin : gemm2_poll
      integer timeout = 0;
      forever begin
        axi_read(ADDR_STAT, status);
        if (status[1]) begin
          $display("[GEMM2] t=%0d DONE! status=%h", cycle, status);
          done_count = done_count + 1;
          disable gemm2_poll;
        end
        timeout = timeout + 1;
        if (timeout > 50000) begin
          $display("[GEMM2] TIMEOUT after %0d cycles! status=%h busy=%0d", timeout, status, npu_busy);
          $display("[GEMM2] DMA phase=%0d core_state=%0d launched=%0d",
            u_npu.u_dma.phase, u_npu.u_core.state, u_npu.u_dma.launched);
          $finish;
        end
      end
    end

    $display("[GEMM2] C[0..5] = %0d %0d %0d %0d %0d %0d",
      $signed(ddr_mem[32'h0200]), $signed(ddr_mem[32'h0201]),
      $signed(ddr_mem[32'h0202]), $signed(ddr_mem[32'h0203]),
      $signed(ddr_mem[32'h0204]), $signed(ddr_mem[32'h0205]));

    // ====================================================================
    // GEMM 3: Different dims — M=2 N=4 K=2 INT8
    // A=[[1,2],[3,4]], B=[[1,0],[0,1],[1,1],[0,0]]
    // Expected C = [[1,2],[3,4]] * B = [[1,2,3,0],[3,4,7,0]]
    // ====================================================================
    // Overwrite A
    ddr_mem[32'h0000] = 8'h01; ddr_mem[32'h0001] = 8'h02;
    ddr_mem[32'h0002] = 8'h03; ddr_mem[32'h0003] = 8'h04;
    // B (2x4): row0={1,0,1,0}, row1={0,1,1,0}
    ddr_mem[32'h0100] = 8'h01; ddr_mem[32'h0101] = 8'h00;
    ddr_mem[32'h0102] = 8'h01; ddr_mem[32'h0103] = 8'h00;
    ddr_mem[32'h0104] = 8'h00; ddr_mem[32'h0105] = 8'h01;
    ddr_mem[32'h0106] = 8'h01; ddr_mem[32'h0107] = 8'h00;

    $display("[GEMM3] t=%0d Triggering NPU: M=2 N=4 K=2 prec=0", cycle);
    axi_write(ADDR_DIM_M,  32'd2);
    axi_write(ADDR_DIM_N,  32'd4);
    axi_write(ADDR_DIM_K,  32'd2);
    axi_write(ADDR_A_BASE, 32'h0000);
    axi_write(ADDR_B_BASE, 32'h0100);
    axi_write(ADDR_C_BASE, 32'h0200);
    axi_write(ADDR_PREC,   32'd0);
    axi_read(ADDR_PREC, status);
    kick_count = kick_count + 1;
    axi_write(ADDR_CTRL, 32'h00000001);
    $display("[GEMM3] t=%0d START written, waiting for done...", cycle);

    begin : gemm3_poll
      integer timeout = 0;
      forever begin
        axi_read(ADDR_STAT, status);
        if (status[1]) begin
          $display("[GEMM3] t=%0d DONE! status=%h", cycle, status);
          done_count = done_count + 1;
          disable gemm3_poll;
        end
        timeout = timeout + 1;
        if (timeout > 50000) begin
          $display("[GEMM3] TIMEOUT after %0d cycles! status=%h busy=%0d", timeout, status, npu_busy);
          $display("[GEMM3] DMA phase=%0d core_state=%0d launched=%0d",
            u_npu.u_dma.phase, u_npu.u_core.state, u_npu.u_dma.launched);
          $finish;
        end
      end
    end

    $display("[GEMM3] C[0..7] = %0d %0d %0d %0d %0d %0d %0d %0d (expect 1 2 3 0 3 4 7 0)",
      $signed(ddr_mem[32'h0200]), $signed(ddr_mem[32'h0201]),
      $signed(ddr_mem[32'h0202]), $signed(ddr_mem[32'h0203]),
      $signed(ddr_mem[32'h0204]), $signed(ddr_mem[32'h0205]),
      $signed(ddr_mem[32'h0206]), $signed(ddr_mem[32'h0207]));

    $display("");
    $display("=================================================");
    $display("  NPU Re-trigger Test: kicks=%0d dones=%0d", kick_count, done_count);
    if (kick_count == done_count)
      $display("  RESULT: PASS");
    else
      $display("  RESULT: FAIL (kicks=%0d but only %0d dones)", kick_count, done_count);
    $display("=================================================");
    $finish;
  end

  // Timeout
  initial begin
    #10000000; // 10M cycles
    $display("[TIMEOUT] Global timeout at t=%0d", cycle);
    $display("  NPU busy=%0d done=%0d DMA phase=%0d core state=%0d",
      npu_busy, npu_done, u_npu.u_dma.phase, u_npu.u_core.state);
    $finish;
  end

endmodule
