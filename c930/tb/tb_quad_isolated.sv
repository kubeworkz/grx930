// -----------------------------------------------------------------------------
// tb_quad_isolated.sv
//
// Minimal isolated harness for the quad-core firmware.  Instantiates the full
// SoC, pokes the quad-core firmware + GEMM operands into DDR, boots all four
// harts, and waits for CPU0 to write the 0xFACEFEED magic to 0x9400 (only
// reached after CPU0, CPU1, CPU2 and CPU3 have each run their GEMM, verified
// their C matrix, and passed the chained-RELEASE handoff).
//
// This validates the 4-core path (two extra harts, widened arbiters, boot-ROM
// park loops) in seconds, without the ~10-minute full suite.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_quad_isolated;

  localparam int MEM_BYTES = 65536;

  logic clk = 0;
  logic rst_n = 0;
  logic o_npu_busy, o_npu_done, o_npu_error, o_npu_irq;
  logic o_npu1_busy, o_npu1_done, o_npu1_error, o_npu1_irq;
  logic o_uart_txd;
  logic i_uart_rxd = 1'b1;
  logic i_tb_wr_en = 1'b0;
  logic [31:0] i_tb_wr_addr = '0;
  logic [7:0]  i_tb_wr_data = '0;

  c930_soc_top #(
    .DDR_INIT_FILE (""),
    .BOOT_INIT_FILE ("sw/boot.hex"),
    .L2_NUM_SETS (16),
    .L2_NUM_WAYS (1),  // tiny L2 for fast Icarus sim; same coherence behavior
    // Bypass the L2 for this 4-hart boot test: the full L2 + 4 active cores
    // exceeds iverilog's usable sim speed.  The L2 itself is verified by
    // tb_l2_coherent (fast, standalone).
    .BYPASS_L2 (1'b1)
  ) dut (
    .i_clk          (clk),
    .i_rst_n        (rst_n),
    .o_npu_busy     (o_npu_busy),
    .o_npu_done     (o_npu_done),
    .o_npu_error    (o_npu_error),
    .o_npu_irq      (o_npu_irq),
    .o_npu1_busy    (o_npu1_busy),
    .o_npu1_done    (o_npu1_done),
    .o_npu1_error   (o_npu1_error),
    .o_npu1_irq     (o_npu1_irq),
    .o_uart_txd     (o_uart_txd),
    .i_uart_rxd     (i_uart_rxd),
    .i_tb_wr_en     (i_tb_wr_en),
    .i_tb_wr_addr   (i_tb_wr_addr),
    .i_tb_wr_data   (i_tb_wr_data)
  );

  always #5 clk = ~clk;

  // Direct DDR poke (same access the full TB uses for ddr_write_byte).
  task automatic ddr_write_byte(input int addr, input logic [7:0] data);
    dut.u_ddr.mem[addr] = data;
  endtask

  // Load a 2-hex-digit-per-token hex file at byte address 0.
  task automatic load_hex(input string fname);
    int fd; logic [7:0] b; int a;
    fd = $fopen(fname, "r");
    if (fd != 0) begin
      a = 0;
      while (!$feof(fd) && a < MEM_BYTES) begin
        if ($fscanf(fd, "%2h", b) == 1) begin
          ddr_write_byte(a, b);
          a = a + 1;
        end
      end
      $fclose(fd);
      $display("  [TB] loaded %0d bytes from %s", a, fname);
    end else begin
      $error("  [FAIL] cannot open %s", fname);
    end
  endtask

  initial begin
    int errs;
    errs = 0;

    // Load firmware
    load_hex("sw/quadcore_ddr_bytes.hex");

    // Operands
    for (int i = 0; i < 16; i++) begin ddr_write_byte(32'h8000+i, 8'h01); ddr_write_byte(32'h8400+i, 8'h01); end
    for (int i = 0; i < 9;  i++) begin ddr_write_byte(32'hA000+i, 8'h02); ddr_write_byte(32'hA400+i, 8'h02); end
    for (int i = 0; i < 9;  i++) begin ddr_write_byte(32'hB000+i, 8'h03); ddr_write_byte(32'hB400+i, 8'h03); end
    for (int i = 0; i < 16; i++) begin ddr_write_byte(32'hD000+i, 8'h04); ddr_write_byte(32'hD400+i, 8'h04); end

    // Clear status + magic region
    for (int i = 0; i < 1280; i++)
      ddr_write_byte(32'h9000 + i, 8'h00);

    // Boot
    rst_n = 1'b0;
    repeat(10) @(posedge clk);
    rst_n = 1'b1;

    // Wait for CPU0 DONE magic
    begin : wait_magic
      int cnt;
      cnt = 0;
      forever begin
        @(posedge clk);
        cnt = cnt + 1;
        if (cnt > 120_000) begin
          $error("  [FAIL] Quad-core isolated TIMEOUT at cycle %0d", cnt);
          errs = errs + 1;
          disable wait_magic;
        end
        begin
          logic [31:0] got;
          got = {dut.u_ddr.mem[32'h9403], dut.u_ddr.mem[32'h9402],
                 dut.u_ddr.mem[32'h9401], dut.u_ddr.mem[32'h9400]};
          if (got == 32'hFACEFEED) begin
            $display("  [PASS] All 4 harts completed in %0d cycles", cnt);
            disable wait_magic;
          end
        end
      end
    end

    // HART_IDs
    begin
      int bad;
      bad = 0;
      for (int c = 0; c < 4; c++) begin
        logic [31:0] got;
        got = {dut.u_ddr.mem[32'h9003 + c*256], dut.u_ddr.mem[32'h9002 + c*256],
               dut.u_ddr.mem[32'h9001 + c*256], dut.u_ddr.mem[32'h9000 + c*256]};
        if (got !== c) begin
          $error("  [FAIL] CPU%0d HART_ID = %0d (expect %0d)", c, got, c);
          bad = bad + 1;
        end
      end
      if (bad == 0)
        $display("  [PASS] HART_IDs = 0,1,2,3");
      errs = errs + bad;
    end

    // C-verify error masks
    begin
      int bad;
      bad = 0;
      for (int c = 0; c < 4; c++) begin
        logic [31:0] got;
        got = {dut.u_ddr.mem[32'h9007 + c*256], dut.u_ddr.mem[32'h9006 + c*256],
               dut.u_ddr.mem[32'h9005 + c*256], dut.u_ddr.mem[32'h9004 + c*256]};
        if (got !== 0) begin
          $error("  [FAIL] CPU%0d C-verify mask = 0x%08h", c, got);
          bad = bad + 1;
        end
      end
      if (bad == 0)
        $display("  [PASS] all four cores verified their C matrices on-core");
      errs = errs + bad;
    end

    // TB C readbacks
    begin
      int bad;
      bad = 0;
      for (int g = 0; g < 4; g++) begin
        int count; int cbase; int cval;
        case (g)
          0: begin count = 16; cbase = 32'h8800; cval = 4;  end
          1: begin count = 9;  cbase = 32'hA800; cval = 12; end
          2: begin count = 9;  cbase = 32'hB800; cval = 27; end
          default: begin count = 16; cbase = 32'hD800; cval = 64; end
        endcase
        for (int i = 0; i < count; i++) begin
          logic [31:0] got;
          got = {dut.u_ddr.mem[cbase+i*4+3], dut.u_ddr.mem[cbase+i*4+2],
                 dut.u_ddr.mem[cbase+i*4+1], dut.u_ddr.mem[cbase+i*4]};
          if (got !== cval) begin
            $error("  [FAIL] GEMM%0d C[%0d] = %0d (expect %0d)", g, i, got, cval);
            bad = bad + 1;
          end
        end
      end
      if (bad == 0)
        $display("  [PASS] TB readback: all 50 C elements across 4 GEMMs correct");
      errs = errs + bad;
    end

    if (errs == 0)
      $display("  QUAD-ISOLATED TEST PASSED");
    else
      $error("  QUAD-ISOLATED FAILED: %0d errors", errs);

    #100;
    $finish;
  end

endmodule