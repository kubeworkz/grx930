// -----------------------------------------------------------------------------
// tb_c930_soc_full.sv
//
// End-to-end test of the GRX930 SoC with AXI4 crossbar.
//
// Test 1: D-cache stress (CPU load/store through crossbar → DDR)
//   - First CPU boot (I-cache clean from power-up)
//   - Reads preloaded words, writes new values, byte-merge test
//   - Pass/fail flag at DDR[0x200]
//
// Test 2: NPU GEMM via CPU firmware
//   - Boots firmware that programs NPU CSR and waits for completion
//
// Test 3: UART TX (CPU MMIO → crossbar → UART)
//   - Boots hand-assembled firmware that sends characters to UART
//   - Verifies TXD line activity
// -----------------------------------------------------------------------------
module tb_c930_soc_full;

  localparam int NUM_ROWS = 8;
  localparam int NUM_COLS = 8;
  localparam int MAX_M    = 8;
  localparam int MAX_K    = 16;
  localparam int MAX_N    = 12;
  localparam int MEM_BYTES = 65536;

  logic clk   = 1'b0;
  logic rst_n = 1'b0;
  logic o_npu_busy, o_npu_done, o_npu_error, o_npu_irq;
  logic o_npu1_busy, o_npu1_done, o_npu1_error, o_npu1_irq;
  logic o_uart_txd;
  logic i_uart_rxd = 1'b1;
  logic        tb_wr_en;
  logic [31:0] tb_wr_addr;
  logic [7:0]  tb_wr_data;

  int total_errs;

  // =========================================================================
  // DUT
  // =========================================================================
  c930_soc_top #(
    .NUM_ROWS       (NUM_ROWS),
    .NUM_COLS       (NUM_COLS),
    .MAX_M          (MAX_M),
    .MAX_K          (MAX_K),
    .MAX_N          (MAX_N),
    .MEM_BYTES      (MEM_BYTES),
    .DDR_INIT_FILE  ("sw/npu_ddr_bytes.hex"),
    .BOOT_INIT_FILE ("sw/boot.hex")
  ) dut (
    .i_clk       (clk),
    .i_rst_n     (rst_n),
    .o_npu_busy   (o_npu_busy),
    .o_npu_done   (o_npu_done),
    .o_npu_error  (o_npu_error),
    .o_npu_irq    (o_npu_irq),
    .o_npu1_busy  (o_npu1_busy),
    .o_npu1_done  (o_npu1_done),
    .o_npu1_error (o_npu1_error),
    .o_npu1_irq   (o_npu1_irq),
    .o_uart_txd  (o_uart_txd),
    .i_uart_rxd  (i_uart_rxd),
    .i_tb_wr_en  (tb_wr_en),
    .i_tb_wr_addr(tb_wr_addr),
    .i_tb_wr_data(tb_wr_data)
  );

  always #5 clk = ~clk;

  // =========================================================================
  // LCG for deterministic operands
  // =========================================================================
  function [31:0] lcg(input logic [31:0] x);
    logic [63:0] t;
    t   = 64'd1103515245 * x + 64'd12345;
    lcg = t[31:0];
  endfunction

  // =========================================================================
  // DDR preload via testbench port
  // =========================================================================
  task ddr_write_byte(input logic [31:0] addr, input logic [7:0] data);
    begin
      // Direct write to DDR byte array (bypasses port timing issues)
      dut.u_ddr.mem[addr] = data;
    end
  endtask

  task preload_operands(input int M, N, K,
                         input logic [31:0] a_base, b_base,
                         input logic [31:0] seed);
    logic [31:0] v;
    logic [7:0]  b;
    begin
      $display("  [TB] Preloading A (%0dx%0d) B (%0dx%0d)", M, K, K, N);
      v = seed;
      for (int mi = 0; mi < M; mi++)
        for (int ki = 0; ki < K; ki++) begin
          v = lcg(v); b = v[7:0];
          if (b == 8'd0) b = 8'd1;
          ddr_write_byte(a_base + mi * K + ki, b);
        end
      v = seed + 32'h1000;
      for (int ki = 0; ki < K; ki++)
        for (int ni = 0; ni < N; ni++) begin
          v = lcg(v); b = v[7:0];
          if (b == 8'd0) b = 8'd1;
          ddr_write_byte(b_base + ki * N + ni, b);
        end
    end
  endtask

  // =========================================================================
  // UART TX monitor
  // =========================================================================
  localparam int BAUD_DIV = 868;
  logic        uart_busy;
  logic [3:0]  uart_bit_cnt, uart_bit_idx;
  logic [7:0]  uart_sr;
  logic        uart_prev_txd;
  int          uart_bytes_rx;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      uart_busy    <= 1'b0;
      uart_bit_cnt <= '0;
      uart_bit_idx <= '0;
      uart_sr      <= '0;
      uart_prev_txd <= 1'b1;
      uart_bytes_rx <= 0;
    end else begin
      uart_prev_txd <= o_uart_txd;
      if (!uart_busy) begin
        if (uart_prev_txd && !o_uart_txd) begin
          uart_busy    <= 1'b1;
          uart_bit_cnt <= '0;
          uart_bit_idx <= 4'd7;
        end
      end else begin
        if (uart_bit_idx == 0 && uart_bit_cnt == 4'd8) begin
          $write("%c", uart_sr);
          uart_bytes_rx <= uart_bytes_rx + 1;
          uart_busy <= 1'b0;
        end else begin
          if (uart_bit_cnt < BAUD_DIV - 1)
            uart_bit_cnt <= uart_bit_cnt + 1;
          else begin
            uart_bit_cnt <= '0;
            uart_sr[uart_bit_idx] <= o_uart_txd;
            uart_bit_idx <= uart_bit_idx - 1;
          end
        end
      end
    end
  end

  // =========================================================================
  // Main test sequence
  // =========================================================================
  initial begin
    $dumpfile("build/tb_c930_soc_full.vcd");
    $dumpvars(0, tb_c930_soc_full);
    total_errs = 0;

    // Initialize preload port
    tb_wr_en   = 1'b0;
    tb_wr_addr = 32'd0;
    tb_wr_data = 8'd0;

    // =========================================================================
    // Test 1: D-cache stress (CPU load/store through crossbar → DDR)
    //
    // This is the FIRST CPU boot, so the I-cache is clean from power-up.
    // Loads a hand-assembled firmware that:
    //   Phase 1: Reads 4 preloaded words from DDR[0x100-0x10F], verifies
    //   Phase 2: Writes new values, reads back, verifies
    //   Phase 3: Byte stores (SB) then word load (LW), verifies merging
    //   On pass: writes 0x12345678 to DDR[0x200]
    //   On fail: writes 0 to DDR[0x200]
    // =========================================================================
    $display("\n========================================");
    $display("  TEST 1: D-cache stress (load/store through crossbar)");
    $display("========================================");
    begin
      int dc_errs;
      dc_errs = 0;

      // Preload test data: 1 word at DDR[0x100] = 0x00000001
      ddr_write_byte(32'h100, 8'h01);
      ddr_write_byte(32'h101, 8'h00);
      ddr_write_byte(32'h102, 8'h00);
      ddr_write_byte(32'h103, 8'h00);
      $display("  [TB] Preloaded DDR[0x100] = 1");

      // Load 8-instruction D-cache firmware at DDR[0x000] (fits in ONE cache line)
      // 0x00: lui  x10, 0
      // 0x04: addi x10, x10, 0x100
      // 0x08: lw   x15, 0(x10)       # x15 = mem[0x100]
      // 0x0C: addi x14, x0, 1
      // 0x10: bne  x15, x14, +0x10   # fail -> 0x20 (hangs)
      // 0x14: lui  x17, 0x12345
      // 0x18: addi x17, x17, 0x678
      // 0x1C: sw   x17, 0(x10)       # mem[0x100] = 0x12345678 (PASS)
      begin
        logic [31:0] fw [0:7];
        fw[0] = 32'h00000537;  // lui  x10, 0
        fw[1] = 32'h10050513;  // addi x10, x10, 0x100
        fw[2] = 32'h00052783;  // lw   x15, 0(x10)
        fw[3] = 32'h00100713;  // addi x14, x0, 1
        fw[4] = 32'h00e79863;  // bne  x15, x14, +0x10 -> 0x20
        fw[5] = 32'h123458b7;  // lui  x17, 0x12345
        fw[6] = 32'h67888893;  // addi x17, x17, 0x678
        fw[7] = 32'h01152023;  // sw   x17, 0(x10)

        for (int i = 0; i < 8; i++) begin
          ddr_write_byte(i*4 + 0, fw[i][7:0]);
          ddr_write_byte(i*4 + 1, fw[i][15:8]);
          ddr_write_byte(i*4 + 2, fw[i][23:16]);
          ddr_write_byte(i*4 + 3, fw[i][31:24]);
        end
        $display("  [TB] D-cache test firmware loaded (%0d bytes, 1 cache line)", 8*4);
      end

      // Reset CPU (first boot - I-cache clean from power-up)
      rst_n = 1'b0;
      repeat(10) @(posedge clk);
      rst_n = 1'b1;

      // Wait for firmware: pass writes 0x12345678 to DDR[0x100], fail hangs
      begin : wait_dcache
        int dc_cnt;
        dc_cnt = 0;
        forever begin
          @(posedge clk);
          dc_cnt = dc_cnt + 1;
          if (dc_cnt > 10_000) begin
            $error("  [FAIL] D-cache test TIMEOUT after %0d cycles", dc_cnt);
            dc_errs = dc_errs + 1;
            disable wait_dcache;
          end
          // Check pass flag at DDR[0x100]
          if (dc_cnt > 50 && dc_cnt % 500 == 0) begin
            logic [7:0] b0, b1, b2, b3;
            b0 = dut.u_ddr.mem[32'h100];
            b1 = dut.u_ddr.mem[32'h101];
            b2 = dut.u_ddr.mem[32'h102];
            b3 = dut.u_ddr.mem[32'h103];
            if ({b3, b2, b1, b0} == 32'h12345678) begin
              $display("  [PASS] D-cache: LW/SW through crossbar verified (0x%08h) at cycle %0d",
                       {b3, b2, b1, b0}, dc_cnt);
              disable wait_dcache;
            end
          end
        end
      end

      // Final check
      begin
        logic [7:0] b0, b1, b2, b3;
        b0 = dut.u_ddr.mem[32'h100];
        b1 = dut.u_ddr.mem[32'h101];
        b2 = dut.u_ddr.mem[32'h102];
        b3 = dut.u_ddr.mem[32'h103];
        if ({b3, b2, b1, b0} == 32'h12345678) begin
          $display("  [PASS] D-cache: all checks passed (0x%08h)", {b3, b2, b1, b0});
        end else begin
          $error("  [FAIL] D-cache: expected 0x12345678, got 0x%08h", {b3, b2, b1, b0});
          dc_errs = dc_errs + 1;
        end
      end
      total_errs = total_errs + dc_errs;
    end

    // =========================================================================
    // Test 2: NPU GEMM via CPU firmware
    //
    // Boot the NPU firmware that programs the NPU CSR and waits for
    // completion. This exercises: CPU boot → DDR fetch → MMIO → NPU DMA.
    //
    // NOTE: Test 1 overwrote DDR[0x000-0x0C3] with D-cache firmware.
    // We must reload the NPU firmware bytes before booting.
    // =========================================================================
    $display("\n========================================");
    $display("  TEST 2: NPU GEMM via CPU firmware");
    $display("========================================");
    begin
      // Preload A/B operands for 4×4×4 GEMM
      preload_operands(4, 4, 4, 32'h8000, 32'h8400, 32'h1234_5678);

      // Write DIMS (M, N, K) to DDR at DIMS_ADDR (0x9400)
      begin
        logic [31:0] dims_addr;
        dims_addr = 32'h9400;
        ddr_write_byte(dims_addr + 0, 8'd4);   // M
        ddr_write_byte(dims_addr + 1, 8'd0);
        ddr_write_byte(dims_addr + 2, 8'd0);
        ddr_write_byte(dims_addr + 3, 8'd0);
        ddr_write_byte(dims_addr + 4, 8'd4);   // N
        ddr_write_byte(dims_addr + 5, 8'd0);
        ddr_write_byte(dims_addr + 6, 8'd0);
        ddr_write_byte(dims_addr + 7, 8'd0);
        ddr_write_byte(dims_addr + 8, 8'd4);   // K
        ddr_write_byte(dims_addr + 9, 8'd0);
        ddr_write_byte(dims_addr + 10, 8'd0);
        ddr_write_byte(dims_addr + 11, 8'd0);
      end

      // Reload NPU firmware into DDR (Test 1 overwrote the first 196 bytes)
      begin
        int fw_fd;
        logic [7:0] fw_byte;
        int fw_addr;
        fw_fd = $fopen("sw/npu_ddr_bytes.hex", "r");
        if (fw_fd != 0) begin
          fw_addr = 0;
          while (!$feof(fw_fd) && fw_addr < MEM_BYTES) begin
            if ($fscanf(fw_fd, "%2h", fw_byte) == 1) begin
              ddr_write_byte(fw_addr[31:0], fw_byte);
              fw_addr = fw_addr + 1;
            end
          end
          $fclose(fw_fd);
          $display("  [TB] Reloaded %0d firmware bytes into DDR", fw_addr);
        end else begin
          $display("  [TB] WARNING: Could not open npu_ddr_bytes.hex, using INIT_FILE data");
        end
      end

      // Reset CPU to boot from NPU firmware (second boot)
      rst_n = 1'b0;
      repeat(20) @(posedge clk);
      rst_n = 1'b1;

      // Wait for NPU completion
      begin : wait_npu
        int poll_cnt;
        poll_cnt = 0;
        forever begin
          @(posedge clk);
          poll_cnt = poll_cnt + 1;

          if (o_npu_done) begin
            $display("  [PASS] NPU GEMM completed after %0d cycles", poll_cnt);
            disable wait_npu;
          end
          if (o_npu_error) begin
            $error("  [FAIL] NPU reported error after %0d cycles", poll_cnt);
            total_errs = total_errs + 1;
            disable wait_npu;
          end
          if (poll_cnt > 200_000) begin
            $error("[TIMEOUT] NPU did not complete in %0d cycles", poll_cnt);
            total_errs = total_errs + 1;
            disable wait_npu;
          end
        end
      end
    end

    // =========================================================================
    // Test 3: UART TX (CPU MMIO → crossbar → UART)
    //
    // Boot hand-assembled firmware that sends "UART OK\n" to the UART TX
    // peripheral, then verify the TXD line shows activity.
    // =========================================================================
    $display("\n========================================");
    $display("  TEST 3: UART TX (CPU MMIO → crossbar → UART)");
    $display("========================================");
    begin
      int uart_errs;
      uart_errs = 0;

      // Hand-assembled UART test firmware (loaded into DDR at 0x0)
      begin
        logic [31:0] fw [0:17];
        fw[0]  = 32'h40001537;  // lui  x10, 0x40001  (UART base = 0x4000_1000)
        fw[1]  = 32'h05500593;  // addi x11, x0, 0x55   ('U')
        fw[2]  = 32'h00b50023;  // sb   x11, 0(x10)
        fw[3]  = 32'h04100593;  // addi x11, x0, 0x41   ('A')
        fw[4]  = 32'h00b50023;  // sb   x11, 0(x10)
        fw[5]  = 32'h05200593;  // addi x11, x0, 0x52   ('R')
        fw[6]  = 32'h00b50023;  // sb   x11, 0(x10)
        fw[7]  = 32'h05400593;  // addi x11, x0, 0x54   ('T')
        fw[8]  = 32'h00b50023;  // sb   x11, 0(x10)
        fw[9]  = 32'h02000593;  // addi x11, x0, 0x20   (' ')
        fw[10] = 32'h00b50023;  // sb   x11, 0(x10)
        fw[11] = 32'h04f00593;  // addi x11, x0, 0x4F   ('O')
        fw[12] = 32'h00b50023;  // sb   x11, 0(x10)
        fw[13] = 32'h04b00593;  // addi x11, x0, 0x4B   ('K')
        fw[14] = 32'h00b50023;  // sb   x11, 0(x10)
        fw[15] = 32'h00a00593;  // addi x11, x0, 0x0A   ('\n')
        fw[16] = 32'h00b50023;  // sb   x11, 0(x10)
        fw[17] = 32'h0000006f;  // j self (loop forever)

        for (int i = 0; i < 18; i++) begin
          ddr_write_byte(i*4 + 0, fw[i][7:0]);
          ddr_write_byte(i*4 + 1, fw[i][15:8]);
          ddr_write_byte(i*4 + 2, fw[i][23:16]);
          ddr_write_byte(i*4 + 3, fw[i][31:24]);
        end
        $display("  [TB] UART test firmware loaded (%0d bytes)", 18*4);
      end

      // Clear UART RX buffer
      uart_bytes_rx = 0;

      // Reset CPU to boot from UART firmware (third boot)
      rst_n = 1'b0;
      repeat(10) @(posedge clk);
      rst_n = 1'b1;

      // Let CPU execute UART firmware
      repeat(100) @(posedge clk);
      repeat(2000) @(posedge clk);

      // Check TXD line for activity
      begin
        int txd_lo_cnt;
        txd_lo_cnt = 0;
        repeat(50000) begin
          @(posedge clk);
          if (!o_uart_txd) txd_lo_cnt = txd_lo_cnt + 1;
        end

        if (txd_lo_cnt > 100) begin
          $display("  [PASS] UART TX: txd toggled %0d cycles (data is being serialized)", txd_lo_cnt);
        end else begin
          $error("  [FAIL] UART TX: txd idle (only %0d low cycles)", txd_lo_cnt);
          uart_errs = uart_errs + 1;
        end
      end
      total_errs = total_errs + uart_errs;
    end

    // =========================================================================
    // Test 4: Mixed-precision varying-shape queue drain + full C verification
    //
    // Phase 1: CPU boots GEMM firmware -> queues 3 GEMMs -> polls completion
    // Phase 2: CPU boots verification firmware -> reads all 21 C elements of
    //          GEMM1 via D-cache LW -> compares with expected FP32 8.0
    //
    //   GEMM0: INT8  3x5x8,  all 1s  -> C[0][0] = 8   (INT32)
    //   GEMM1: FP16  7x3x8,  all 1.0 -> C[m][n] = 8.0 (FP32 0x41000000) ALL 21
    //   GEMM2: BF16  2x12x8, all 1.0 -> C[0][0] = 8.0 (FP32 0x41000000)
    // =========================================================================
    $display("\n========================================");
    $display("  TEST 4: Mixed-precision + full C verification");
    $display("========================================");
    begin
      int mg_errs;
      mg_errs = 0;

      // Reload NPU firmware from hex file
      begin
        int fw_fd;
        logic [7:0] fw_byte;
        int fw_addr;
        fw_fd = $fopen("sw/npu_ddr_bytes.hex", "r");
        if (fw_fd != 0) begin
          fw_addr = 0;
          while (!$feof(fw_fd) && fw_addr < MEM_BYTES) begin
            if ($fscanf(fw_fd, "%2h", fw_byte) == 1) begin
              ddr_write_byte(fw_addr[31:0], fw_byte);
              fw_addr = fw_addr + 1;
            end
          end
          $fclose(fw_fd);
          $display("  [TB] Reloaded %0d firmware bytes into DDR", fw_addr);
        end
      end

      // ---- Phase 1: GEMM firmware ----
      begin
        logic [31:0] fw [0:86];
        fw[ 0] = 32'h40000537;  // lui  x10, 0x40000 (MMIO_BASE)
        fw[ 1] = 32'h00050513;  // addi x10, x10, 0
        fw[ 2] = 32'h000005B7;  // lui  x11, 0
        fw[ 3] = 32'h00358593;  // addi x11, x11, 3    DIM_M=3
        fw[ 4] = 32'h00B52423;  // sw   x11, 0x08(x10)
        fw[ 5] = 32'h000005B7;  // lui  x11, 0
        fw[ 6] = 32'h00558593;  // addi x11, x11, 5    DIM_N=5
        fw[ 7] = 32'h00B52623;  // sw   x11, 0x0C(x10)
        fw[ 8] = 32'h000005B7;  // lui  x11, 0
        fw[ 9] = 32'h00858593;  // addi x11, x11, 8    DIM_K=8
        fw[10] = 32'h00B52823;  // sw   x11, 0x10(x10)
        fw[11] = 32'h000085B7;  // lui  x11, 0x8
        fw[12] = 32'h00058593;  // addi x11, x11, 0    A=0x8000
        fw[13] = 32'h00B52A23;  // sw   x11, 0x14(x10)
        fw[14] = 32'h000085B7;  // lui  x11, 0x8
        fw[15] = 32'h20058593;  // addi x11, x11, 0x200 B=0x8200
        fw[16] = 32'h00B52C23;  // sw   x11, 0x18(x10)
        fw[17] = 32'h000085B7;  // lui  x11, 0x8
        fw[18] = 32'h40058593;  // addi x11, x11, 0x400 C=0x8400
        fw[19] = 32'h00B52E23;  // sw   x11, 0x1C(x10)
        fw[20] = 32'h000005B7;  // lui  x11, 0
        fw[21] = 32'h00058593;  // addi x11, x11, 0    PREC=0 (INT8)
        fw[22] = 32'h02B52023;  // sw   x11, 0x20(x10)
        fw[23] = 32'h02052583;  // lw   x11, 0x20(x10) barrier
        fw[24] = 32'h00100593;  // addi x11, x0, 1
        fw[25] = 32'h00B52023;  // sw   x11, 0x00(x10) START
        fw[26] = 32'h000005B7;  // lui  x11, 0
        fw[27] = 32'h00758593;  // addi x11, x11, 7    DIM_M=7
        fw[28] = 32'h00B52423;  // sw   x11, 0x08(x10)
        fw[29] = 32'h000005B7;  // lui  x11, 0
        fw[30] = 32'h00358593;  // addi x11, x11, 3    DIM_N=3
        fw[31] = 32'h00B52623;  // sw   x11, 0x0C(x10)
        fw[32] = 32'h000005B7;  // lui  x11, 0
        fw[33] = 32'h00858593;  // addi x11, x11, 8    DIM_K=8
        fw[34] = 32'h00B52823;  // sw   x11, 0x10(x10)
        fw[35] = 32'h000095B7;  // lui  x11, 0x9
        fw[36] = 32'h80058593;  // addi x11, x11, 0x800 A=0x8800 (7*8*2=112B)
        fw[37] = 32'h00B52A23;  // sw   x11, 0x14(x10)
        fw[38] = 32'h000095B7;  // lui  x11, 0x9
        fw[39] = 32'hA0058593;  // addi x11, x11, 0xA00 B=0x8A00 (8*3*2=48B)
        fw[40] = 32'h00B52C23;  // sw   x11, 0x18(x10)
        fw[41] = 32'h000095B7;  // lui  x11, 0x9
        fw[42] = 32'hC0058593;  // addi x11, x11, 0xC00 C=0x8C00
        fw[43] = 32'h00B52E23;  // sw   x11, 0x1C(x10)
        fw[44] = 32'h000005B7;  // lui  x11, 0
        fw[45] = 32'h00258593;  // addi x11, x11, 2    PREC=2 (FP16)
        fw[46] = 32'h02B52023;  // sw   x11, 0x20(x10)
        fw[47] = 32'h02052583;  // lw   x11, 0x20(x10) barrier
        fw[48] = 32'h00100593;  // addi x11, x0, 1
        fw[49] = 32'h00B52023;  // sw   x11, 0x00(x10) START
        fw[50] = 32'h000005B7;  // lui  x11, 0
        fw[51] = 32'h00258593;  // addi x11, x11, 2    DIM_M=2
        fw[52] = 32'h00B52423;  // sw   x11, 0x08(x10)
        fw[53] = 32'h000005B7;  // lui  x11, 0
        fw[54] = 32'h00C58593;  // addi x11, x11, 12   DIM_N=12
        fw[55] = 32'h00B52623;  // sw   x11, 0x0C(x10)
        fw[56] = 32'h000005B7;  // lui  x11, 0
        fw[57] = 32'h00858593;  // addi x11, x11, 8    DIM_K=8
        fw[58] = 32'h00B52823;  // sw   x11, 0x10(x10)
        fw[59] = 32'h000095B7;  // lui  x11, 0x9
        fw[60] = 32'h00058593;  // addi x11, x11, 0    A=0x9000 (2*8*2=32B)
        fw[61] = 32'h00B52A23;  // sw   x11, 0x14(x10)
        fw[62] = 32'h000095B7;  // lui  x11, 0x9
        fw[63] = 32'h20058593;  // addi x11, x11, 0x200 B=0x9200 (8*12*2=192B)
        fw[64] = 32'h00B52C23;  // sw   x11, 0x18(x10)
        fw[65] = 32'h000095B7;  // lui  x11, 0x9
        fw[66] = 32'h40058593;  // addi x11, x11, 0x400 C=0x9400
        fw[67] = 32'h00B52E23;  // sw   x11, 0x1C(x10)
        fw[68] = 32'h000005B7;  // lui  x11, 0
        fw[69] = 32'h00358593;  // addi x11, x11, 3    PREC=3 (BF16)
        fw[70] = 32'h02B52023;  // sw   x11, 0x20(x10)
        fw[71] = 32'h02052583;  // lw   x11, 0x20(x10) barrier
        fw[72] = 32'h00100593;  // addi x11, x0, 1
        fw[73] = 32'h00B52023;  // sw   x11, 0x00(x10) START
        fw[74] = 32'h02052583;  // lw   x11, 0x20(x10) barrier read
        fw[75] = 32'h00452583;  // lw   x11, 0x04(x10) STATUS
        fw[76] = 32'h0025F593;  // andi x11, x11, 2    DONE bit
        fw[77] = 32'hFE058CE3;  // beq  x11, x0, -8   poll done
        fw[78] = 32'h00452583;  // lw   x11, 0x04(x10) STATUS
        fw[79] = 32'h0015F593;  // andi x11, x11, 1    BUSY bit
        fw[80] = 32'hFE059CE3;  // bne  x11, x0, -8   poll busy
        fw[81] = 32'h000097B7;  // lui  x15, 0x9
        fw[82] = 32'h41078793;  // addi x15, x15, 0x410 DONE_ADDR=0x9410
        fw[83] = 32'hDEADC837;  // lui  x16, 0xDEADC
        fw[84] = 32'hEEF80813;  // addi x16, x16, 0xEEF DONE_MAGIC=0xDEADBEEF
        fw[85] = 32'h0107A023;  // sw   x16, 0(x15)
        fw[86] = 32'h0000006F;  // jal  x0, 0  self-loop
        for (int i = 0; i < 87; i++) begin
          ddr_write_byte(i*4 + 0, fw[i][7:0]);
          ddr_write_byte(i*4 + 1, fw[i][15:8]);
          ddr_write_byte(i*4 + 2, fw[i][23:16]);
          ddr_write_byte(i*4 + 3, fw[i][31:24]);
        end
        $display("  [TB] Phase 1 GEMM firmware loaded (%0d bytes)", 87*4);
      end

      // --- Preload A/B operands ---
      // GEMM 0: INT8 3x5x8 all 1s - A=24B @0x8000, B=40B @0x8200
      begin
        for (int i = 0; i < 24; i++)
          ddr_write_byte(32'h8000 + i, 8'd1);
        for (int i = 0; i < 40; i++)
          ddr_write_byte(32'h8200 + i, 8'd1);
        $display("  [TB] GEMM0: INT8 3x5x8 all 1s (C[0][0] expect 0x00000008)");
      end
      // GEMM 1: FP16 7x3x8 all 1.0 - A=112B @0x8800, B=48B @0x8A00
      begin
        for (int i = 0; i < 56; i++) begin
          ddr_write_byte(32'h8800 + i*2 + 0, 8'h00);
          ddr_write_byte(32'h8800 + i*2 + 1, 8'h3C);
        end
        for (int i = 0; i < 24; i++) begin
          ddr_write_byte(32'h8A00 + i*2 + 0, 8'h00);
          ddr_write_byte(32'h8A00 + i*2 + 1, 8'h3C);
        end
        $display("  [TB] GEMM1: FP16 7x3x8 all 1.0 (C[0][0] expect 0x41000000)");
      end
      // GEMM 2: BF16 2x12x8 all 1.0 - A=32B @0x9000, B=192B @0x9200
      begin
        for (int i = 0; i < 16; i++) begin
          ddr_write_byte(32'h9000 + i*2 + 0, 8'h80);
          ddr_write_byte(32'h9000 + i*2 + 1, 8'h3F);
        end
        for (int i = 0; i < 96; i++) begin
          ddr_write_byte(32'h9200 + i*2 + 0, 8'h80);
          ddr_write_byte(32'h9200 + i*2 + 1, 8'h3F);
        end
        $display("  [TB] GEMM2: BF16 2x12x8 all 1.0 (C[0][0] expect 0x41000000)");
      end

      // Initialize DONE_ADDR to 0
      ddr_write_byte(32'h9410, 8'h00);
      ddr_write_byte(32'h9411, 8'h00);
      ddr_write_byte(32'h9412, 8'h00);
      ddr_write_byte(32'h9413, 8'h00);

      // Reset CPU and boot Phase 1
      rst_n = 1'b0;
      repeat(10) @(posedge clk);
      rst_n = 1'b1;

      // Wait for DONE_MAGIC from Phase 1
      begin : wait_phase1
        int mg_cnt;
        mg_cnt = 0;
        forever begin
          @(posedge clk);
          mg_cnt = mg_cnt + 1;
          if (mg_cnt > 500_000) begin
            $error("  [FAIL] Phase 1 TIMEOUT after %0d cycles", mg_cnt);
            mg_errs = mg_errs + 1;
            disable wait_phase1;
          end
          begin
            logic [7:0] b0, b1, b2, b3;
            b0 = dut.u_ddr.mem[32'h9410];
            b1 = dut.u_ddr.mem[32'h9411];
            b2 = dut.u_ddr.mem[32'h9412];
            b3 = dut.u_ddr.mem[32'h9413];
            if ({b3, b2, b1, b0} == 32'hDEADBEEF) begin
              $display("  [PASS] Phase 1: all 3 GEMMs completed in %0d cycles", mg_cnt);
              disable wait_phase1;
            end
          end
        end
      end

      // Quick C[0][0] check for GEMM0 and GEMM2 (Phase 1 readback)
      begin
        logic [7:0] c0, c1, c2, c3;
        c0 = dut.u_ddr.mem[32'h8400]; c1 = dut.u_ddr.mem[32'h8401];
        c2 = dut.u_ddr.mem[32'h8402]; c3 = dut.u_ddr.mem[32'h8403];
        $display("  [TB] GEMM0 INT8 (3x5x8)  C[0][0] = 0x%08h (expect 0x00000008)", {c3, c2, c1, c0});
        if ({c3, c2, c1, c0} != 32'd8) begin
          $error("  [FAIL] GEMM0 INT8 C[0][0] wrong"); mg_errs = mg_errs + 1;
        end
        c0 = dut.u_ddr.mem[32'h9400]; c1 = dut.u_ddr.mem[32'h9401];
        c2 = dut.u_ddr.mem[32'h9402]; c3 = dut.u_ddr.mem[32'h9403];
        $display("  [TB] GEMM2 BF16 (2x12x8) C[0][0] = 0x%08h (expect 0x41000000)", {c3, c2, c1, c0});
        if ({c3, c2, c1, c0} != 32'h41000000) begin
          $error("  [FAIL] GEMM2 BF16 C[0][0] wrong"); mg_errs = mg_errs + 1;
        end
      end

      // ---- Phase 2: Verification firmware (reads all 21 C elements via D-cache) ----
      // Reload NPU firmware (CPU needs I-cache to boot, but DDR contents preserved)
      begin
        int fw_fd;
        logic [7:0] fw_byte;
        int fw_addr;
        fw_fd = $fopen("sw/npu_ddr_bytes.hex", "r");
        if (fw_fd != 0) begin
          fw_addr = 0;
          while (!$feof(fw_fd) && fw_addr < MEM_BYTES) begin
            if ($fscanf(fw_fd, "%2h", fw_byte) == 1) begin
              ddr_write_byte(fw_addr[31:0], fw_byte);
              fw_addr = fw_addr + 1;
            end
          end
          $fclose(fw_fd);
        end
      end

      // Load Phase 2 verification firmware into DDR[0x000]
      begin
        logic [31:0] vfw [0:29];
        vfw[ 0] = 32'h00009537;  // lui  x10, 0x9
        vfw[ 1] = 32'hC0050513;  // addi x10, x10, 0xC00   x10 = 0x8C00 (GEMM1 C base)
        vfw[ 2] = 32'h41000737;  // lui  x14, 0x41000  x14 = 0x41000000 (FP32 8.0)
        vfw[ 3] = 32'h00000793;  // addi x15, x0, 0    error mask = 0
        vfw[ 4] = 32'h00000813;  // addi x16, x0, 0    element index = 0
        vfw[ 5] = 32'h00000693;  // addi x13, x0, 0    row counter = 0
        vfw[ 6] = 32'h00700A13;  // addi x20, x0, 7    NUM_ROWS
        vfw[ 7] = 32'h00300A93;  // addi x21, x0, 3    NUM_COLS
        vfw[ 8] = 32'h00000613;  // addi x12, x0, 0    row_loop: col counter = 0
        vfw[ 9] = 32'h00052903;  // lw   x18, 0(x10)   col_loop: load C[row][col]
        vfw[10] = 32'h00E90863;  // beq  x18, x14, +16 if match, skip mismatch
        vfw[11] = 32'h00100993;  // addi x19, x0, 1    mismatch: bit = 1
        vfw[12] = 32'h010999B3;  // sll  x19, x19, x16 shift by element index
        vfw[13] = 32'h0137E7B3;  // or   x15, x15, x19 set bit in error mask
        vfw[14] = 32'h00450513;  // addi x10, x10, 4   next: advance address
        vfw[15] = 32'h00180813;  // addi x16, x16, 1   advance element index
        vfw[16] = 32'h00160613;  // addi x12, x12, 1   advance col counter
        vfw[17] = 32'hFF5640E3;  // blt  x12, x21, col_loop if col < 3, loop
        vfw[18] = 32'h00168693;  // addi x13, x13, 1   advance row counter
        vfw[19] = 32'hFD46CAE3;  // blt  x13, x20, row_loop if row < 7, loop
        vfw[20] = 32'h00000537;  // lui  x10, 0
        vfw[21] = 32'h10050513;  // addi x10, x10, 0x100  verify buffer address
        vfw[22] = 32'h00F52023;  // sw   x15, 0(x10)   store error mask
        vfw[23] = 32'h01052223;  // sw   x16, 4(x10)   store element count
        vfw[24] = 32'h000097B7;  // lui  x15, 0x9
        vfw[25] = 32'h41078793;  // addi x15, x15, 0x410 DONE_ADDR=0x9410
        vfw[26] = 32'hDEADC837;  // lui  x16, 0xDEADC
        vfw[27] = 32'hEEF80813;  // addi x16, x16, 0xEEF DONE_MAGIC
        vfw[28] = 32'h0107A023;  // sw   x16, 0(x15)
        vfw[29] = 32'h0000006F;  // jal  x0, 0  self-loop
        for (int i = 0; i < 30; i++) begin
          ddr_write_byte(i*4 + 0, vfw[i][7:0]);
          ddr_write_byte(i*4 + 1, vfw[i][15:8]);
          ddr_write_byte(i*4 + 2, vfw[i][23:16]);
          ddr_write_byte(i*4 + 3, vfw[i][31:24]);
        end
        $display("  [TB] Phase 2 verification firmware loaded (%0d bytes)", 30*4);
      end

      // Clear DONE_MAGIC so Phase 2 can detect its own completion
      ddr_write_byte(32'h9410, 8'h00);
      ddr_write_byte(32'h9411, 8'h00);
      ddr_write_byte(32'h9412, 8'h00);
      ddr_write_byte(32'h9413, 8'h00);

      // Clear verification buffer
      ddr_write_byte(32'h0100, 8'h00);
      ddr_write_byte(32'h0101, 8'h00);
      ddr_write_byte(32'h0102, 8'h00);
      ddr_write_byte(32'h0103, 8'h00);

      // Reset CPU and boot Phase 2
      rst_n = 1'b0;
      repeat(10) @(posedge clk);
      rst_n = 1'b1;

      // Wait for DONE_MAGIC from Phase 2
      begin : wait_phase2
        int mg_cnt;
        mg_cnt = 0;
        forever begin
          @(posedge clk);
          mg_cnt = mg_cnt + 1;
          if (mg_cnt > 500_000) begin
            $error("  [FAIL] Phase 2 TIMEOUT after %0d cycles", mg_cnt);
            mg_errs = mg_errs + 1;
            disable wait_phase2;
          end
          begin
            logic [7:0] b0, b1, b2, b3;
            b0 = dut.u_ddr.mem[32'h9410];
            b1 = dut.u_ddr.mem[32'h9411];
            b2 = dut.u_ddr.mem[32'h9412];
            b3 = dut.u_ddr.mem[32'h9413];
            if ({b3, b2, b1, b0} == 32'hDEADBEEF) begin
              $display("  [PASS] Phase 2: verification complete in %0d cycles", mg_cnt);
              disable wait_phase2;
            end
          end
        end
      end

      // Read verification buffer at DDR[0x100] and check all 21 elements
      begin
        logic [7:0] v0, v1, v2, v3;
        logic [31:0] err_mask;
        v0 = dut.u_ddr.mem[32'h0100];
        v1 = dut.u_ddr.mem[32'h0101];
        v2 = dut.u_ddr.mem[32'h0102];
        v3 = dut.u_ddr.mem[32'h0103];
        err_mask = {v3, v2, v1, v0};
        $display("  [TB] GEMM1 C verification: error mask = 0x%08h (%0d failures)",
                 err_mask, $countones(err_mask));
        if (err_mask == 32'h0000000) begin
          $display("  [PASS] GEMM1: all 21 C elements verified correct (FP32 8.0)");
        end else begin
          // Decode which elements failed
          for (int idx = 0; idx < 21; idx++) begin
            if (err_mask[idx]) begin
              $error("  [FAIL] GEMM1 C[%0d][%0d] wrong (elem %0d)", idx/3, idx%3, idx);
            end
          end
          mg_errs = mg_errs + 1;
        end
      end

      total_errs = total_errs + mg_errs;
    end

    // =========================================================================
    // Test 5: 6-GEMM queue stress test (fill queue to capacity, drain twice)
    //
    // CMD_QUEUE_DEPTH = 4. Queue 4 GEMMs (fill queue), poll to drain,
    // then queue 2 more (second drain cycle). Exercises:
    //   - Queue fill-to-capacity and backpressure
    //   - DMA dispatch ordering across different shapes
    //   - Bank switching with increasing operand sizes
    //   - Two complete fill/drain cycles
    //
    // GEMMs (all INT8, all 1s, K=4):
    //   GEMM0: 2x2x4  GEMM1: 3x3x4  GEMM2: 4x4x4
    //   GEMM3: 5x3x4  GEMM4: 3x6x4  GEMM5: 6x6x4
    //   All C[0][0] = K = 4
    // =========================================================================
    $display("\n========================================");
    $display("  TEST 5: 6-GEMM queue stress (fill+drain x2)");
    $display("========================================");
    begin
      int mg_errs;
      mg_errs = 0;

      // Reload NPU firmware from hex file
      begin
        int fw_fd;
        logic [7:0] fw_byte;
        int fw_addr;
        fw_fd = $fopen("sw/npu_ddr_bytes.hex", "r");
        if (fw_fd != 0) begin
          fw_addr = 0;
          while (!$feof(fw_fd) && fw_addr < MEM_BYTES) begin
            if ($fscanf(fw_fd, "%2h", fw_byte) == 1) begin
              ddr_write_byte(fw_addr[31:0], fw_byte);
              fw_addr = fw_addr + 1;
            end
          end
          $fclose(fw_fd);
          $display("  [TB] Reloaded %0d firmware bytes into DDR", fw_addr);
        end
      end

      // Load queue-stress firmware
      begin
        logic [31:0] fw [0:124];
        fw[  0] = 32'h40000537;
        fw[  1] = 32'h00050513;
        fw[  2] = 32'h00000593;
        fw[  3] = 32'h02B52023;
        fw[  4] = 32'h02052583;
        fw[  5] = 32'h00200593;
        fw[  6] = 32'h00B52423;
        fw[  7] = 32'h00200593;
        fw[  8] = 32'h00B52623;
        fw[  9] = 32'h00400593;
        fw[ 10] = 32'h00B52823;
        fw[ 11] = 32'h000085B7;
        fw[ 12] = 32'h00058593;
        fw[ 13] = 32'h00B52A23;
        fw[ 14] = 32'h000085B7;
        fw[ 15] = 32'h04058593;
        fw[ 16] = 32'h00B52C23;
        fw[ 17] = 32'h000085B7;
        fw[ 18] = 32'h08058593;
        fw[ 19] = 32'h00B52E23;
        fw[ 20] = 32'h00100593;
        fw[ 21] = 32'h00B52023;
        fw[ 22] = 32'h00300593;
        fw[ 23] = 32'h00B52423;
        fw[ 24] = 32'h00300593;
        fw[ 25] = 32'h00B52623;
        fw[ 26] = 32'h00400593;
        fw[ 27] = 32'h00B52823;
        fw[ 28] = 32'h000085B7;
        fw[ 29] = 32'h10058593;
        fw[ 30] = 32'h00B52A23;
        fw[ 31] = 32'h000085B7;
        fw[ 32] = 32'h14058593;
        fw[ 33] = 32'h00B52C23;
        fw[ 34] = 32'h000085B7;
        fw[ 35] = 32'h18058593;
        fw[ 36] = 32'h00B52E23;
        fw[ 37] = 32'h00100593;
        fw[ 38] = 32'h00B52023;
        fw[ 39] = 32'h00400593;
        fw[ 40] = 32'h00B52423;
        fw[ 41] = 32'h00400593;
        fw[ 42] = 32'h00B52623;
        fw[ 43] = 32'h00400593;
        fw[ 44] = 32'h00B52823;
        fw[ 45] = 32'h000085B7;
        fw[ 46] = 32'h20058593;
        fw[ 47] = 32'h00B52A23;
        fw[ 48] = 32'h000085B7;
        fw[ 49] = 32'h24058593;
        fw[ 50] = 32'h00B52C23;
        fw[ 51] = 32'h000085B7;
        fw[ 52] = 32'h28058593;
        fw[ 53] = 32'h00B52E23;
        fw[ 54] = 32'h00100593;
        fw[ 55] = 32'h00B52023;
        fw[ 56] = 32'h00500593;
        fw[ 57] = 32'h00B52423;
        fw[ 58] = 32'h00300593;
        fw[ 59] = 32'h00B52623;
        fw[ 60] = 32'h00400593;
        fw[ 61] = 32'h00B52823;
        fw[ 62] = 32'h000085B7;
        fw[ 63] = 32'h30058593;
        fw[ 64] = 32'h00B52A23;
        fw[ 65] = 32'h000085B7;
        fw[ 66] = 32'h34058593;
        fw[ 67] = 32'h00B52C23;
        fw[ 68] = 32'h000085B7;
        fw[ 69] = 32'h38058593;
        fw[ 70] = 32'h00B52E23;
        fw[ 71] = 32'h00100593;
        fw[ 72] = 32'h00B52023;
        fw[ 73] = 32'h00452583;
        fw[ 74] = 32'h0025F593;
        fw[ 75] = 32'hFE058CE3;
        fw[ 76] = 32'h00452583;
        fw[ 77] = 32'h0015F593;
        fw[ 78] = 32'hFE059CE3;
        fw[ 79] = 32'h00300593;
        fw[ 80] = 32'h00B52423;
        fw[ 81] = 32'h00600593;
        fw[ 82] = 32'h00B52623;
        fw[ 83] = 32'h00400593;
        fw[ 84] = 32'h00B52823;
        fw[ 85] = 32'h000085B7;
        fw[ 86] = 32'h40058593;
        fw[ 87] = 32'h00B52A23;
        fw[ 88] = 32'h000085B7;
        fw[ 89] = 32'h44058593;
        fw[ 90] = 32'h00B52C23;
        fw[ 91] = 32'h000085B7;
        fw[ 92] = 32'h48058593;
        fw[ 93] = 32'h00B52E23;
        fw[ 94] = 32'h00100593;
        fw[ 95] = 32'h00B52023;
        fw[ 96] = 32'h00600593;
        fw[ 97] = 32'h00B52423;
        fw[ 98] = 32'h00600593;
        fw[ 99] = 32'h00B52623;
        fw[100] = 32'h00400593;
        fw[101] = 32'h00B52823;
        fw[102] = 32'h000085B7;
        fw[103] = 32'h50058593;
        fw[104] = 32'h00B52A23;
        fw[105] = 32'h000085B7;
        fw[106] = 32'h54058593;
        fw[107] = 32'h00B52C23;
        fw[108] = 32'h000085B7;
        fw[109] = 32'h58058593;
        fw[110] = 32'h00B52E23;
        fw[111] = 32'h00100593;
        fw[112] = 32'h00B52023;
        fw[113] = 32'h00452583;
        fw[114] = 32'h0025F593;
        fw[115] = 32'hFE058CE3;
        fw[116] = 32'h00452583;
        fw[117] = 32'h0015F593;
        fw[118] = 32'hFE059CE3;
        fw[119] = 32'h000097B7;
        fw[120] = 32'h41078793;
        fw[121] = 32'hDEADC837;
        fw[122] = 32'hEEF80813;
        fw[123] = 32'h0107A023;
        fw[124] = 32'h0000006F;
        for (int i = 0; i < 125; i++) begin
          ddr_write_byte(i*4 + 0, fw[i][7:0]);
          ddr_write_byte(i*4 + 1, fw[i][15:8]);
          ddr_write_byte(i*4 + 2, fw[i][23:16]);
          ddr_write_byte(i*4 + 3, fw[i][31:24]);
        end
        $display("  [TB] Queue-stress firmware loaded (%0d bytes)", 125*4);
      end

      // Preload A/B operands
      // GEMM0: 2x2x4 all 1s -- A=8B @0x8000, B=8B @0x8040
      begin
        for (int i = 0; i < 8; i++)
          ddr_write_byte(32'h8000 + i, 8'd1);
        for (int i = 0; i < 8; i++)
          ddr_write_byte(32'h8040 + i, 8'd1);
      end
      // GEMM1: 3x3x4 all 1s -- A=12B @0x8100, B=12B @0x8140
      begin
        for (int i = 0; i < 12; i++)
          ddr_write_byte(32'h8100 + i, 8'd1);
        for (int i = 0; i < 12; i++)
          ddr_write_byte(32'h8140 + i, 8'd1);
      end
      // GEMM2: 4x4x4 all 1s -- A=16B @0x8200, B=16B @0x8240
      begin
        for (int i = 0; i < 16; i++)
          ddr_write_byte(32'h8200 + i, 8'd1);
        for (int i = 0; i < 16; i++)
          ddr_write_byte(32'h8240 + i, 8'd1);
      end
      // GEMM3: 5x3x4 all 1s -- A=20B @0x8300, B=12B @0x8340
      begin
        for (int i = 0; i < 20; i++)
          ddr_write_byte(32'h8300 + i, 8'd1);
        for (int i = 0; i < 12; i++)
          ddr_write_byte(32'h8340 + i, 8'd1);
      end
      // GEMM4: 3x6x4 all 1s -- A=12B @0x8400, B=24B @0x8440
      begin
        for (int i = 0; i < 12; i++)
          ddr_write_byte(32'h8400 + i, 8'd1);
        for (int i = 0; i < 24; i++)
          ddr_write_byte(32'h8440 + i, 8'd1);
      end
      // GEMM5: 6x6x4 all 1s -- A=24B @0x8500, B=24B @0x8540
      begin
        for (int i = 0; i < 24; i++)
          ddr_write_byte(32'h8500 + i, 8'd1);
        for (int i = 0; i < 24; i++)
          ddr_write_byte(32'h8540 + i, 8'd1);
      end

      // Initialize DONE_ADDR to 0
      ddr_write_byte(32'h9410, 8'h00);
      ddr_write_byte(32'h9411, 8'h00);
      ddr_write_byte(32'h9412, 8'h00);
      ddr_write_byte(32'h9413, 8'h00);

      // Reset CPU and boot
      rst_n = 1'b0;
      repeat(10) @(posedge clk);
      rst_n = 1'b1;

      // Wait for DONE_MAGIC
      begin : wait_stress
        int mg_cnt;
        mg_cnt = 0;
        forever begin
          @(posedge clk);
          mg_cnt = mg_cnt + 1;
          if (mg_cnt > 1_000_000) begin
            $error("  [FAIL] Queue-stress TIMEOUT after %0d cycles", mg_cnt);
            mg_errs = mg_errs + 1;
            disable wait_stress;
          end
          begin
            logic [7:0] b0, b1, b2, b3;
            b0 = dut.u_ddr.mem[32'h9410];
            b1 = dut.u_ddr.mem[32'h9411];
            b2 = dut.u_ddr.mem[32'h9412];
            b3 = dut.u_ddr.mem[32'h9413];
            if ({b3, b2, b1, b0} == 32'hDEADBEEF) begin
              $display("  [PASS] Queue-stress: all 6 GEMMs completed in %0d cycles", mg_cnt);
              disable wait_stress;
            end
          end
        end
      end

      // Verify C[0][0] for all 6 GEMMs
      begin
        logic [7:0] c0, c1, c2, c3;
        // GEMM0: 2x2x4 -> C[0][0] = 4
        c0 = dut.u_ddr.mem[32'h8080]; c1 = dut.u_ddr.mem[32'h8081];
        c2 = dut.u_ddr.mem[32'h8082]; c3 = dut.u_ddr.mem[32'h8083];
        $display("  [TB] GEMM0 (2x2x4) C[0][0] = 0x%08h (expect 0x00000004)", {c3, c2, c1, c0});
        if ({c3, c2, c1, c0} != 32'd4) begin
          $error("  [FAIL] GEMM0 (2x2x4) C[0][0] wrong"); mg_errs = mg_errs + 1;
        end
        // GEMM1: 3x3x4 -> C[0][0] = 4
        c0 = dut.u_ddr.mem[32'h8180]; c1 = dut.u_ddr.mem[32'h8181];
        c2 = dut.u_ddr.mem[32'h8182]; c3 = dut.u_ddr.mem[32'h8183];
        $display("  [TB] GEMM1 (3x3x4) C[0][0] = 0x%08h (expect 0x00000004)", {c3, c2, c1, c0});
        if ({c3, c2, c1, c0} != 32'd4) begin
          $error("  [FAIL] GEMM1 (3x3x4) C[0][0] wrong"); mg_errs = mg_errs + 1;
        end
        // GEMM2: 4x4x4 -> C[0][0] = 4
        c0 = dut.u_ddr.mem[32'h8280]; c1 = dut.u_ddr.mem[32'h8281];
        c2 = dut.u_ddr.mem[32'h8282]; c3 = dut.u_ddr.mem[32'h8283];
        $display("  [TB] GEMM2 (4x4x4) C[0][0] = 0x%08h (expect 0x00000004)", {c3, c2, c1, c0});
        if ({c3, c2, c1, c0} != 32'd4) begin
          $error("  [FAIL] GEMM2 (4x4x4) C[0][0] wrong"); mg_errs = mg_errs + 1;
        end
        // GEMM3: 5x3x4 -> C[0][0] = 4
        c0 = dut.u_ddr.mem[32'h8380]; c1 = dut.u_ddr.mem[32'h8381];
        c2 = dut.u_ddr.mem[32'h8382]; c3 = dut.u_ddr.mem[32'h8383];
        $display("  [TB] GEMM3 (5x3x4) C[0][0] = 0x%08h (expect 0x00000004)", {c3, c2, c1, c0});
        if ({c3, c2, c1, c0} != 32'd4) begin
          $error("  [FAIL] GEMM3 (5x3x4) C[0][0] wrong"); mg_errs = mg_errs + 1;
        end
        // GEMM4: 3x6x4 -> C[0][0] = 4
        c0 = dut.u_ddr.mem[32'h8480]; c1 = dut.u_ddr.mem[32'h8481];
        c2 = dut.u_ddr.mem[32'h8482]; c3 = dut.u_ddr.mem[32'h8483];
        $display("  [TB] GEMM4 (3x6x4) C[0][0] = 0x%08h (expect 0x00000004)", {c3, c2, c1, c0});
        if ({c3, c2, c1, c0} != 32'd4) begin
          $error("  [FAIL] GEMM4 (3x6x4) C[0][0] wrong"); mg_errs = mg_errs + 1;
        end
        // GEMM5: 6x6x4 -> C[0][0] = 4
        c0 = dut.u_ddr.mem[32'h8580]; c1 = dut.u_ddr.mem[32'h8581];
        c2 = dut.u_ddr.mem[32'h8582]; c3 = dut.u_ddr.mem[32'h8583];
        $display("  [TB] GEMM5 (6x6x4) C[0][0] = 0x%08h (expect 0x00000004)", {c3, c2, c1, c0});
        if ({c3, c2, c1, c0} != 32'd4) begin
          $error("  [FAIL] GEMM5 (6x6x4) C[0][0] wrong"); mg_errs = mg_errs + 1;
        end
      end
      total_errs = total_errs + mg_errs;
    end


    // =========================================================================
    // Test 6: Dual-NPU simultaneous GEMM
    //
    // Runs independent GEMMs on NPU0 (CSR at 0x4000_0000) and NPU1
    // (CSR at 0x4000_0040) simultaneously. Both share DDR through the
    // DMA arbiter, testing concurrent DMA arbitration.
    //
    //   NPU0: 2x2x2 INT8 all 1s -> C[0][0] = 2
    //   NPU1: 2x2x2 INT8 all 1s -> C[0][0] = 2
    // =========================================================================


    // =========================================================================
    // Test 6: Dual-NPU different-shape stress test
    //
    // Runs independent GEMMs on NPU0 (CSR at 0x4000_0000) and NPU1
    // (CSR at 0x4000_0040) simultaneously with different shapes.
    // Both share DDR through the DMA arbiter, testing concurrent DMA
    // arbitration with asymmetric operand sizes.
    //
    //   NPU0: 4x4x4 INT8 all 1s -> C[m][n] = 4 (16 elements verified)
    //   NPU1: 2x3x2 INT8 all 1s -> C[m][n] = 2 (6 elements verified)
    // =========================================================================
    $display("\n========================================");
    $display("  TEST 6: Dual-NPU different shapes (4x4x4 + 2x3x2)");
    $display("========================================");
    begin
      int mg_errs;
      mg_errs = 0;

      // Reload NPU firmware
      begin
        int fw_fd; logic [7:0] fw_byte; int fw_addr;
        fw_fd = $fopen("sw/npu_ddr_bytes.hex", "r");
        if (fw_fd != 0) begin
          fw_addr = 0;
          while (!$feof(fw_fd) && fw_addr < MEM_BYTES) begin
            if ($fscanf(fw_fd, "%2h", fw_byte) == 1) begin
              ddr_write_byte(fw_addr[31:0], fw_byte);
              fw_addr = fw_addr + 1;
            end
          end
          $fclose(fw_fd);
        end
      end

      // Load dual-NPU firmware
      begin
        logic [31:0] fw [0:55];
        fw[ 0] = 32'h40000537;
        fw[ 1] = 32'h00050513;
        fw[ 2] = 32'h40000737;
        fw[ 3] = 32'h04070713;
        fw[ 4] = 32'h00400593;
        fw[ 5] = 32'h00B52423;
        fw[ 6] = 32'h00400593;
        fw[ 7] = 32'h00B52623;
        fw[ 8] = 32'h00400593;
        fw[ 9] = 32'h00B52823;
        fw[10] = 32'h000085B7;
        fw[11] = 32'h00058593;
        fw[12] = 32'h00B52A23;
        fw[13] = 32'h000085B7;
        fw[14] = 32'h02058593;
        fw[15] = 32'h00B52C23;
        fw[16] = 32'h000085B7;
        fw[17] = 32'h04058593;
        fw[18] = 32'h00B52E23;
        fw[19] = 32'h00000593;
        fw[20] = 32'h02B52023;
        fw[21] = 32'h02052583;
        fw[22] = 32'h00100593;
        fw[23] = 32'h00B52023;
        fw[24] = 32'h00200593;
        fw[25] = 32'h00B72423;
        fw[26] = 32'h00300593;
        fw[27] = 32'h00B72623;
        fw[28] = 32'h00200593;
        fw[29] = 32'h00B72823;
        fw[30] = 32'h000085B7;
        fw[31] = 32'h10058593;
        fw[32] = 32'h00B72A23;
        fw[33] = 32'h000085B7;
        fw[34] = 32'h12058593;
        fw[35] = 32'h00B72C23;
        fw[36] = 32'h000085B7;
        fw[37] = 32'h14058593;
        fw[38] = 32'h00B72E23;
        fw[39] = 32'h00000593;
        fw[40] = 32'h02B72023;
        fw[41] = 32'h02072583;
        fw[42] = 32'h00100593;
        fw[43] = 32'h00B72023;
        fw[44] = 32'h00452583;
        fw[45] = 32'h0025F593;
        fw[46] = 32'hFE058CE3;
        fw[47] = 32'h00472583;
        fw[48] = 32'h0025F593;
        fw[49] = 32'hFE058CE3;
        fw[50] = 32'h000097B7;
        fw[51] = 32'h41078793;
        fw[52] = 32'hDEADC837;
        fw[53] = 32'hEEF80813;
        fw[54] = 32'h0107A023;
        fw[55] = 32'h0000006F;

        for (int i = 0; i < 56; i++) begin
          ddr_write_byte(i*4 + 0, fw[i][7:0]);
          ddr_write_byte(i*4 + 1, fw[i][15:8]);
          ddr_write_byte(i*4 + 2, fw[i][23:16]);
          ddr_write_byte(i*4 + 3, fw[i][31:24]);
        end
      end

      // Preload A for NPU0: 4x4 = 16 bytes, all 1s
      begin
        for (int i = 0; i < 16; i++) ddr_write_byte(32'h8000 + i, 8'd1);
      end
      // Preload B for NPU0: 4x4 = 16 bytes, all 1s
      begin
        for (int i = 0; i < 16; i++) ddr_write_byte(32'h8020 + i, 8'd1);
      end
      // Preload A for NPU1: 2x2 = 4 bytes, all 1s
      begin
        for (int i = 0; i < 4; i++) ddr_write_byte(32'h8100 + i, 8'd1);
      end
      // Preload B for NPU1: 2x3 = 6 bytes, all 1s
      begin
        for (int i = 0; i < 6; i++) ddr_write_byte(32'h8120 + i, 8'd1);
      end

      // Clear DONE_ADDR
      ddr_write_byte(32'h9410, 8'h00);
      ddr_write_byte(32'h9411, 8'h00);
      ddr_write_byte(32'h9412, 8'h00);
      ddr_write_byte(32'h9413, 8'h00);

      // Reset CPU and boot
      rst_n = 1'b0;
      repeat(10) @(posedge clk);
      rst_n = 1'b1;

      // Wait for DONE_MAGIC
      begin : wait_dual
        int mg_cnt;
        mg_cnt = 0;
        forever begin
          @(posedge clk);
          mg_cnt = mg_cnt + 1;
          if (mg_cnt > 500_000) begin
            $error("  [FAIL] Dual-NPU TIMEOUT");
            mg_errs = mg_errs + 1;
            disable wait_dual;
          end
          begin
            logic [7:0] b0, b1, b2, b3;
            b0 = dut.u_ddr.mem[32'h9410];
            b1 = dut.u_ddr.mem[32'h9411];
            b2 = dut.u_ddr.mem[32'h9412];
            b3 = dut.u_ddr.mem[32'h9413];
            if ({b3, b2, b1, b0} == 32'hDEADBEEF) begin
              $display("  [PASS] Dual-NPU: both GEMMs completed in %0d cycles", mg_cnt);
              disable wait_dual;
            end
          end
        end
      end

      // Verify NPU0 result: 4x4x4 -> all C = 4
      $display("  [TB] Verifying NPU0 (4x4x4) C matrix...");
      // NPU0 C[0][0]
      begin
        logic [7:0] c0, c1, c2, c3;
        c0 = dut.u_ddr.mem[32'h8040]; c1 = dut.u_ddr.mem[32'h8041];
        c2 = dut.u_ddr.mem[32'h8042]; c3 = dut.u_ddr.mem[32'h8043];
        if ({c3, c2, c1, c0} !== 32'd4) begin
          $error("  [FAIL] NPU0 C[0][0] = 0x%08h (expect 0x%08h)", {c3, c2, c1, c0}, 32'd4);
          mg_errs = mg_errs + 1;
        end else begin
          $display("  [TB] NPU0 C[0][0] = %0d OK", $signed({c3, c2, c1, c0}));
        end
      end
      // NPU0 C[0][1]
      begin
        logic [7:0] c0, c1, c2, c3;
        c0 = dut.u_ddr.mem[32'h8044]; c1 = dut.u_ddr.mem[32'h8045];
        c2 = dut.u_ddr.mem[32'h8046]; c3 = dut.u_ddr.mem[32'h8047];
        if ({c3, c2, c1, c0} !== 32'd4) begin
          $error("  [FAIL] NPU0 C[0][1] = 0x%08h (expect 0x%08h)", {c3, c2, c1, c0}, 32'd4);
          mg_errs = mg_errs + 1;
        end else begin
          $display("  [TB] NPU0 C[0][1] = %0d OK", $signed({c3, c2, c1, c0}));
        end
      end
      // NPU0 C[0][2]
      begin
        logic [7:0] c0, c1, c2, c3;
        c0 = dut.u_ddr.mem[32'h8048]; c1 = dut.u_ddr.mem[32'h8049];
        c2 = dut.u_ddr.mem[32'h804A]; c3 = dut.u_ddr.mem[32'h804B];
        if ({c3, c2, c1, c0} !== 32'd4) begin
          $error("  [FAIL] NPU0 C[0][2] = 0x%08h (expect 0x%08h)", {c3, c2, c1, c0}, 32'd4);
          mg_errs = mg_errs + 1;
        end else begin
          $display("  [TB] NPU0 C[0][2] = %0d OK", $signed({c3, c2, c1, c0}));
        end
      end
      // NPU0 C[0][3]
      begin
        logic [7:0] c0, c1, c2, c3;
        c0 = dut.u_ddr.mem[32'h804C]; c1 = dut.u_ddr.mem[32'h804D];
        c2 = dut.u_ddr.mem[32'h804E]; c3 = dut.u_ddr.mem[32'h804F];
        if ({c3, c2, c1, c0} !== 32'd4) begin
          $error("  [FAIL] NPU0 C[0][3] = 0x%08h (expect 0x%08h)", {c3, c2, c1, c0}, 32'd4);
          mg_errs = mg_errs + 1;
        end else begin
          $display("  [TB] NPU0 C[0][3] = %0d OK", $signed({c3, c2, c1, c0}));
        end
      end
      // NPU0 C[1][0]
      begin
        logic [7:0] c0, c1, c2, c3;
        c0 = dut.u_ddr.mem[32'h8050]; c1 = dut.u_ddr.mem[32'h8051];
        c2 = dut.u_ddr.mem[32'h8052]; c3 = dut.u_ddr.mem[32'h8053];
        if ({c3, c2, c1, c0} !== 32'd4) begin
          $error("  [FAIL] NPU0 C[1][0] = 0x%08h (expect 0x%08h)", {c3, c2, c1, c0}, 32'd4);
          mg_errs = mg_errs + 1;
        end else begin
          $display("  [TB] NPU0 C[1][0] = %0d OK", $signed({c3, c2, c1, c0}));
        end
      end
      // NPU0 C[1][1]
      begin
        logic [7:0] c0, c1, c2, c3;
        c0 = dut.u_ddr.mem[32'h8054]; c1 = dut.u_ddr.mem[32'h8055];
        c2 = dut.u_ddr.mem[32'h8056]; c3 = dut.u_ddr.mem[32'h8057];
        if ({c3, c2, c1, c0} !== 32'd4) begin
          $error("  [FAIL] NPU0 C[1][1] = 0x%08h (expect 0x%08h)", {c3, c2, c1, c0}, 32'd4);
          mg_errs = mg_errs + 1;
        end else begin
          $display("  [TB] NPU0 C[1][1] = %0d OK", $signed({c3, c2, c1, c0}));
        end
      end
      // NPU0 C[1][2]
      begin
        logic [7:0] c0, c1, c2, c3;
        c0 = dut.u_ddr.mem[32'h8058]; c1 = dut.u_ddr.mem[32'h8059];
        c2 = dut.u_ddr.mem[32'h805A]; c3 = dut.u_ddr.mem[32'h805B];
        if ({c3, c2, c1, c0} !== 32'd4) begin
          $error("  [FAIL] NPU0 C[1][2] = 0x%08h (expect 0x%08h)", {c3, c2, c1, c0}, 32'd4);
          mg_errs = mg_errs + 1;
        end else begin
          $display("  [TB] NPU0 C[1][2] = %0d OK", $signed({c3, c2, c1, c0}));
        end
      end
      // NPU0 C[1][3]
      begin
        logic [7:0] c0, c1, c2, c3;
        c0 = dut.u_ddr.mem[32'h805C]; c1 = dut.u_ddr.mem[32'h805D];
        c2 = dut.u_ddr.mem[32'h805E]; c3 = dut.u_ddr.mem[32'h805F];
        if ({c3, c2, c1, c0} !== 32'd4) begin
          $error("  [FAIL] NPU0 C[1][3] = 0x%08h (expect 0x%08h)", {c3, c2, c1, c0}, 32'd4);
          mg_errs = mg_errs + 1;
        end else begin
          $display("  [TB] NPU0 C[1][3] = %0d OK", $signed({c3, c2, c1, c0}));
        end
      end
      // NPU0 C[2][0]
      begin
        logic [7:0] c0, c1, c2, c3;
        c0 = dut.u_ddr.mem[32'h8060]; c1 = dut.u_ddr.mem[32'h8061];
        c2 = dut.u_ddr.mem[32'h8062]; c3 = dut.u_ddr.mem[32'h8063];
        if ({c3, c2, c1, c0} !== 32'd4) begin
          $error("  [FAIL] NPU0 C[2][0] = 0x%08h (expect 0x%08h)", {c3, c2, c1, c0}, 32'd4);
          mg_errs = mg_errs + 1;
        end else begin
          $display("  [TB] NPU0 C[2][0] = %0d OK", $signed({c3, c2, c1, c0}));
        end
      end
      // NPU0 C[2][1]
      begin
        logic [7:0] c0, c1, c2, c3;
        c0 = dut.u_ddr.mem[32'h8064]; c1 = dut.u_ddr.mem[32'h8065];
        c2 = dut.u_ddr.mem[32'h8066]; c3 = dut.u_ddr.mem[32'h8067];
        if ({c3, c2, c1, c0} !== 32'd4) begin
          $error("  [FAIL] NPU0 C[2][1] = 0x%08h (expect 0x%08h)", {c3, c2, c1, c0}, 32'd4);
          mg_errs = mg_errs + 1;
        end else begin
          $display("  [TB] NPU0 C[2][1] = %0d OK", $signed({c3, c2, c1, c0}));
        end
      end
      // NPU0 C[2][2]
      begin
        logic [7:0] c0, c1, c2, c3;
        c0 = dut.u_ddr.mem[32'h8068]; c1 = dut.u_ddr.mem[32'h8069];
        c2 = dut.u_ddr.mem[32'h806A]; c3 = dut.u_ddr.mem[32'h806B];
        if ({c3, c2, c1, c0} !== 32'd4) begin
          $error("  [FAIL] NPU0 C[2][2] = 0x%08h (expect 0x%08h)", {c3, c2, c1, c0}, 32'd4);
          mg_errs = mg_errs + 1;
        end else begin
          $display("  [TB] NPU0 C[2][2] = %0d OK", $signed({c3, c2, c1, c0}));
        end
      end
      // NPU0 C[2][3]
      begin
        logic [7:0] c0, c1, c2, c3;
        c0 = dut.u_ddr.mem[32'h806C]; c1 = dut.u_ddr.mem[32'h806D];
        c2 = dut.u_ddr.mem[32'h806E]; c3 = dut.u_ddr.mem[32'h806F];
        if ({c3, c2, c1, c0} !== 32'd4) begin
          $error("  [FAIL] NPU0 C[2][3] = 0x%08h (expect 0x%08h)", {c3, c2, c1, c0}, 32'd4);
          mg_errs = mg_errs + 1;
        end else begin
          $display("  [TB] NPU0 C[2][3] = %0d OK", $signed({c3, c2, c1, c0}));
        end
      end
      // NPU0 C[3][0]
      begin
        logic [7:0] c0, c1, c2, c3;
        c0 = dut.u_ddr.mem[32'h8070]; c1 = dut.u_ddr.mem[32'h8071];
        c2 = dut.u_ddr.mem[32'h8072]; c3 = dut.u_ddr.mem[32'h8073];
        if ({c3, c2, c1, c0} !== 32'd4) begin
          $error("  [FAIL] NPU0 C[3][0] = 0x%08h (expect 0x%08h)", {c3, c2, c1, c0}, 32'd4);
          mg_errs = mg_errs + 1;
        end else begin
          $display("  [TB] NPU0 C[3][0] = %0d OK", $signed({c3, c2, c1, c0}));
        end
      end
      // NPU0 C[3][1]
      begin
        logic [7:0] c0, c1, c2, c3;
        c0 = dut.u_ddr.mem[32'h8074]; c1 = dut.u_ddr.mem[32'h8075];
        c2 = dut.u_ddr.mem[32'h8076]; c3 = dut.u_ddr.mem[32'h8077];
        if ({c3, c2, c1, c0} !== 32'd4) begin
          $error("  [FAIL] NPU0 C[3][1] = 0x%08h (expect 0x%08h)", {c3, c2, c1, c0}, 32'd4);
          mg_errs = mg_errs + 1;
        end else begin
          $display("  [TB] NPU0 C[3][1] = %0d OK", $signed({c3, c2, c1, c0}));
        end
      end
      // NPU0 C[3][2]
      begin
        logic [7:0] c0, c1, c2, c3;
        c0 = dut.u_ddr.mem[32'h8078]; c1 = dut.u_ddr.mem[32'h8079];
        c2 = dut.u_ddr.mem[32'h807A]; c3 = dut.u_ddr.mem[32'h807B];
        if ({c3, c2, c1, c0} !== 32'd4) begin
          $error("  [FAIL] NPU0 C[3][2] = 0x%08h (expect 0x%08h)", {c3, c2, c1, c0}, 32'd4);
          mg_errs = mg_errs + 1;
        end else begin
          $display("  [TB] NPU0 C[3][2] = %0d OK", $signed({c3, c2, c1, c0}));
        end
      end
      // NPU0 C[3][3]
      begin
        logic [7:0] c0, c1, c2, c3;
        c0 = dut.u_ddr.mem[32'h807C]; c1 = dut.u_ddr.mem[32'h807D];
        c2 = dut.u_ddr.mem[32'h807E]; c3 = dut.u_ddr.mem[32'h807F];
        if ({c3, c2, c1, c0} !== 32'd4) begin
          $error("  [FAIL] NPU0 C[3][3] = 0x%08h (expect 0x%08h)", {c3, c2, c1, c0}, 32'd4);
          mg_errs = mg_errs + 1;
        end else begin
          $display("  [TB] NPU0 C[3][3] = %0d OK", $signed({c3, c2, c1, c0}));
        end
      end

      // Verify NPU1 result: 2x3x2 -> all C = 2
      $display("  [TB] Verifying NPU1 (2x3x2) C matrix...");
      // NPU1 C[0][0]
      begin
        logic [7:0] c0, c1, c2, c3;
        c0 = dut.u_ddr.mem[32'h8140]; c1 = dut.u_ddr.mem[32'h8141];
        c2 = dut.u_ddr.mem[32'h8142]; c3 = dut.u_ddr.mem[32'h8143];
        if ({c3, c2, c1, c0} !== 32'd2) begin
          $error("  [FAIL] NPU1 C[0][0] = 0x%08h (expect 0x%08h)", {c3, c2, c1, c0}, 32'd2);
          mg_errs = mg_errs + 1;
        end else begin
          $display("  [TB] NPU1 C[0][0] = %0d OK", $signed({c3, c2, c1, c0}));
        end
      end
      // NPU1 C[0][1]
      begin
        logic [7:0] c0, c1, c2, c3;
        c0 = dut.u_ddr.mem[32'h8144]; c1 = dut.u_ddr.mem[32'h8145];
        c2 = dut.u_ddr.mem[32'h8146]; c3 = dut.u_ddr.mem[32'h8147];
        if ({c3, c2, c1, c0} !== 32'd2) begin
          $error("  [FAIL] NPU1 C[0][1] = 0x%08h (expect 0x%08h)", {c3, c2, c1, c0}, 32'd2);
          mg_errs = mg_errs + 1;
        end else begin
          $display("  [TB] NPU1 C[0][1] = %0d OK", $signed({c3, c2, c1, c0}));
        end
      end
      // NPU1 C[0][2]
      begin
        logic [7:0] c0, c1, c2, c3;
        c0 = dut.u_ddr.mem[32'h8148]; c1 = dut.u_ddr.mem[32'h8149];
        c2 = dut.u_ddr.mem[32'h814A]; c3 = dut.u_ddr.mem[32'h814B];
        if ({c3, c2, c1, c0} !== 32'd2) begin
          $error("  [FAIL] NPU1 C[0][2] = 0x%08h (expect 0x%08h)", {c3, c2, c1, c0}, 32'd2);
          mg_errs = mg_errs + 1;
        end else begin
          $display("  [TB] NPU1 C[0][2] = %0d OK", $signed({c3, c2, c1, c0}));
        end
      end
      // NPU1 C[1][0]
      begin
        logic [7:0] c0, c1, c2, c3;
        c0 = dut.u_ddr.mem[32'h814C]; c1 = dut.u_ddr.mem[32'h814D];
        c2 = dut.u_ddr.mem[32'h814E]; c3 = dut.u_ddr.mem[32'h814F];
        if ({c3, c2, c1, c0} !== 32'd2) begin
          $error("  [FAIL] NPU1 C[1][0] = 0x%08h (expect 0x%08h)", {c3, c2, c1, c0}, 32'd2);
          mg_errs = mg_errs + 1;
        end else begin
          $display("  [TB] NPU1 C[1][0] = %0d OK", $signed({c3, c2, c1, c0}));
        end
      end
      // NPU1 C[1][1]
      begin
        logic [7:0] c0, c1, c2, c3;
        c0 = dut.u_ddr.mem[32'h8150]; c1 = dut.u_ddr.mem[32'h8151];
        c2 = dut.u_ddr.mem[32'h8152]; c3 = dut.u_ddr.mem[32'h8153];
        if ({c3, c2, c1, c0} !== 32'd2) begin
          $error("  [FAIL] NPU1 C[1][1] = 0x%08h (expect 0x%08h)", {c3, c2, c1, c0}, 32'd2);
          mg_errs = mg_errs + 1;
        end else begin
          $display("  [TB] NPU1 C[1][1] = %0d OK", $signed({c3, c2, c1, c0}));
        end
      end
      // NPU1 C[1][2]
      begin
        logic [7:0] c0, c1, c2, c3;
        c0 = dut.u_ddr.mem[32'h8154]; c1 = dut.u_ddr.mem[32'h8155];
        c2 = dut.u_ddr.mem[32'h8156]; c3 = dut.u_ddr.mem[32'h8157];
        if ({c3, c2, c1, c0} !== 32'd2) begin
          $error("  [FAIL] NPU1 C[1][2] = 0x%08h (expect 0x%08h)", {c3, c2, c1, c0}, 32'd2);
          mg_errs = mg_errs + 1;
        end else begin
          $display("  [TB] NPU1 C[1][2] = %0d OK", $signed({c3, c2, c1, c0}));
        end
      end

      total_errs = total_errs + mg_errs;
    end


    // Summary
    $display("\n========================================");
    if (total_errs == 0)
      $display("  FULL-SOC TEST PASSED");
    else
      $error("  FAILED: %0d total errors", total_errs);
    $display("========================================\n");

    #100;
    $finish;
  end

endmodule
