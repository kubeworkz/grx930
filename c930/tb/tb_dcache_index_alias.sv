// tb_dcache_index_alias.sv
//
// D-cache twin of tb_icache_index_alias.sv: the same literal addr[11:5] tag set
// select against an INDEX_WIDTH-wide data array. A = 0x0000 and B = 0x00A0 share
// addr[11:8] (the buggy data index) but differ in addr[8:5] (the correct index);
// the DDR model puts each line's own addresses in the line, so a hit that serves
// the wrong line fails on DATA rather than hiding as a miss.
//
// Loads are dword (size 2'b11) so one access maps to one 64-bit word of the line.
//
// Run: ./run_cache_index_alias.sh <rtl-dir>
module tb_dcache_index_alias;

  localparam int W    = 4;            // the chip's setting (grx930_test_chip.sv)
  localparam int TAGW = 64 - 5 - W;

  logic clk = 1'b0;
  logic rst_n = 1'b0;

  logic [63:0] data_from_core = 64'd0;
  logic [63:0] addr_from_core = 64'd0;
  logic        read  = 1'b0;
  logic        write = 1'b0;
  logic [1:0]  size  = 2'b11;         // dword
  logic [3:0]  amo_op = 4'd0;
  logic        amo = 1'b0, lr = 1'b0, sc = 1'b0;
  logic        stall;
  logic [63:0] data_to_core;
  logic        store_fault, load_fault, amo_fault;

  logic [63:0]  dmem_rd_addr;
  logic         dmem_rd_req;
  logic         dmem_rd_done = 1'b0;
  logic [255:0] dmem_rd_line = '0;
  logic [63:0]  dmem_wr_addr, dmem_wr_data;
  logic [7:0]   dmem_wr_strobe;
  logic         dmem_wr_valid;
  logic         dmem_wr_done = 1'b0;

  logic [63:0] mmio_rd_addr, mmio_wr_addr, mmio_wr_data;
  logic        mmio_rd_req, mmio_rd_done = 1'b0, mmio_wr_valid, mmio_wr_done = 1'b0;
  logic [63:0] mmio_rd_data = 64'd0;
  logic [7:0]  mmio_wr_strobe;

  int fills  = 0;
  int errors = 0;
  int addr_errs = 0;   // fill-address decomposition errors (orphaned bits)

  // The other half of the decomposition: tag = addr[63:5+W] and index =
  // addr[5+:W] must RECONSTRUCT the line being fetched, so every fill request
  // has to be line-aligned and point at the line of the core's address.
  task automatic check_fill_addr(input [63:0] req, input [63:0] want);
    if (req[4:0] !== 5'b0) begin
      addr_errs++;
      $display("[FAIL] dcache fill addr %h is not line-aligned (offset bits not zero)", req);
    end else if (req[63:5] !== want[63:5]) begin
      addr_errs++;
      $display("[FAIL] dcache fill addr %h does not match the requested line %h", req, {want[63:5], 5'b0});
    end
  endtask

  riscv_core_dcache_top #(
    .INDEX_WIDTH(W),
    .TAG_WIDTH  (TAGW),
    .MMIO_BASE  (64'h4000_0000)
  ) dut (
    .i_clk               (clk),
    .i_rst_n             (rst_n),
    .i_data_from_core    (data_from_core),
    .i_addr_from_core    (addr_from_core),
    .i_read              (read),
    .i_write             (write),
    .i_size              (size),
    .i_amo_op            (amo_op),
    .i_amo               (amo),
    .i_lr                (lr),
    .i_sc                (sc),
    .o_stall             (stall),
    .o_data_to_core      (data_to_core),
    .o_store_fault       (store_fault),
    .o_load_fault        (load_fault),
    .o_amo_fault         (amo_fault),
    .o_mem_read_address  (dmem_rd_addr),
    .o_mem_read_req      (dmem_rd_req),
    .i_mem_read_done     (dmem_rd_done),
    .i_block_from_axi    (dmem_rd_line),
    .i_mem_write_done    (dmem_wr_done),
    .o_mem_write_valid   (dmem_wr_valid),
    .o_mem_write_data    (dmem_wr_data),
    .o_mem_write_address (dmem_wr_addr),
    .o_mem_write_strobe  (dmem_wr_strobe),
    .o_mmio_read_address (mmio_rd_addr),
    .o_mmio_read_req     (mmio_rd_req),
    .i_mmio_read_done    (mmio_rd_done),
    .i_mmio_read_data    (mmio_rd_data),
    .o_mmio_write_address(mmio_wr_addr),
    .o_mmio_write_data   (mmio_wr_data),
    .o_mmio_write_strobe (mmio_wr_strobe),
    .o_mmio_write_valid  (mmio_wr_valid),
    .i_mmio_write_done   (mmio_wr_done)
  );

  always #5 clk = ~clk;

  // DDR model: 64-bit word j of the line at base B is (B + 8*j), so a correct
  // dword load of any 8-aligned address X returns exactly X.
  function automatic [255:0] line_for(input [63:0] a);
    logic [63:0] base;
    begin
      base = {a[63:5], 5'b0};
      for (int j = 0; j < 4; j++) line_for[64*j +: 64] = base + 8*j;
    end
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dmem_rd_done <= 1'b0;
      dmem_rd_line <= '0;
      dmem_wr_done <= 1'b0;
    end else begin
      dmem_rd_done <= 1'b0;
      dmem_wr_done <= 1'b0;
      if (dmem_rd_req && !dmem_rd_done) begin
        dmem_rd_line <= line_for(dmem_rd_addr);
        dmem_rd_done <= 1'b1;
        fills        <= fills + 1;
        check_fill_addr(dmem_rd_addr, addr_from_core);
      end
      if (dmem_wr_valid) begin
        dmem_wr_done <= 1'b1;
        $display("[FAIL] unexpected cache write-through at %h (this test is loads only)",
                 dmem_wr_addr);
        errors++;
      end
    end
  end

  // One dword load: hold the request until the cache releases o_stall
  // (LOAD_DONE, when the registered read is presented), check the data, then
  // retire the request before the next dispatch.
  // No `break` anywhere: iverilog 12.0 rejects it ("sorry: break statements
  // not supported"), so the wait is a guarded while.
  task automatic load(input [63:0] a, input [63:0] exp);
    bit got   = 1'b0;
    int guard = 0;
    addr_from_core = a;
    read = 1'b1;
    while (!got && guard < 500) begin
      @(posedge clk);
      guard = guard + 1;
      if (!stall) got = 1'b1;
    end
    if (!got) begin
      errors++;
      $display("[FAIL] dcache addr=%h: no data within 500 cycles", a);
    end else if (data_to_core !== exp) begin
      errors++;
      $display("[FAIL] dcache addr=%h: got %h expected %h (wrong line served on HIT)",
               a, data_to_core, exp);
    end else begin
      $display("[ok  ] dcache addr=%h -> %h", a, data_to_core);
    end
    read = 1'b0;
    @(posedge clk);
  endtask

  localparam [63:0] A = 64'h0000_0000;   // addr[8:5]=0 -> set 0 (correct)
  localparam [63:0] B = 64'h0000_00A0;   // addr[8:5]=5; addr[11:8]=0, same as A

  initial begin
    $display("== dcache index/tag alias regression: INDEX_WIDTH=%0d, TAG_WIDTH=%0d ==", W, TAGW);
    repeat (4) @(posedge clk);
    rst_n = 1'b1;

    load(A, A);                                    // miss + fill
    if (fills != 1) begin errors++; $display("[FAIL] expected 1 fill after A, got %0d", fills); end

    load(A, A);                                    // hit
    if (fills != 1) begin errors++; $display("[FAIL] A re-load refilled (%0d fills): not a hit", fills); end

    load(B, B);                                    // miss + fill of a different set
    if (fills != 2) begin errors++; $display("[FAIL] expected 2 fills after B, got %0d", fills); end

    load(A, A);                                    // DISCRIMINATING: hit, must still be A's line
    if (fills != 2) begin errors++; $display("[FAIL] A after B refilled (%0d fills)", fills); end

    load(B, B);                                    // hit
    if (fills != 2) begin errors++; $display("[FAIL] B re-load refilled (%0d fills)", fills); end

    if (errors == 0 && addr_errs == 0) $display("RESULT: PASS (dcache, %0d fills, fill addresses decomposed correctly)", fills);
    else             $display("RESULT: FAIL (dcache, %0d error(s), %0d address error(s), %0d fills)", errors, addr_errs, fills);
    $finish;
  end

endmodule
