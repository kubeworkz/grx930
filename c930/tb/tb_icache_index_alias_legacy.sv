// tb_icache_index_alias_legacy.sv
//
// Legacy-generation twin of tb_icache_index_alias.sv: the same literal
// addr[11:5] tag set select against an INDEX_WIDTH-wide data array, for the
// older icache tops that have no cache-invalidation ports.
//
// The pair below is discriminating by construction: A = 0x0000 and B = 0x00A0
// share addr[11:8] (the buggy data index) but differ in addr[8:5] (the correct
// index), and the DDR model hands back a line that contains its own addresses,
// so a wrong line shows up as wrong DATA -- exactly what the old RTL hid.
//
// Run: ./run_cache_index_alias_legacy.sh <tree> <caches|fpga>
module tb_icache_index_alias_legacy;

`ifdef W_OVERRIDE
  localparam int W    = `W_OVERRIDE;   // override with -DW_OVERRIDE=<n>
`else
  localparam int W    = 4;
`endif
  localparam int TAGW = 64 - 5 - W;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic [63:0]  pc = 64'h0;
  logic         stall;
  logic [31:0]  word;
  logic [63:0]  axi_addr;
  logic         mem_req;
  logic         mem_done = 1'b0;
  logic [255:0] block = '0;

  int fills  = 0;
  int errors = 0;
  int addr_errs = 0;

  // tag = addr[63:5+W] and index = addr[5+:W] must RECONSTRUCT the line being
  // fetched, so every fill request has to be line-aligned and point at the line
  // of the address the core asked for.
  task automatic check_fill_addr(input [63:0] req, input [63:0] want);
    if (req[4:0] !== 5'b0) begin
      addr_errs++;
      $display("[FAIL] icache fill addr %h is not line-aligned (offset bits not zero)", req);
    end else if (req[63:5] !== want[63:5]) begin
      addr_errs++;
      $display("[FAIL] icache fill addr %h does not match the requested line %h", req, {want[63:5], 5'b0});
    end
  endtask

  riscv_core_icache_top #(
    .INDEX_WIDTH(W),
    .TAG_WIDTH  (TAGW)
  ) dut (
    .i_clk                     (clk),
    .i_rst_n                   (rst_n),
    .i_addr_from_core          (pc),
    .o_stall                   (stall),
    .o_data_to_core            (word),
    .o_addr_from_control_to_axi(axi_addr),
    .o_mem_req                 (mem_req),
    .i_mem_done                (mem_done),
    .i_block_from_axi          (block)
  );

  always #5 clk = ~clk;

  // DDR model: 32-bit word j of the line at base B is (B + 4*j), so a correct
  // fetch of any 4-aligned address X returns exactly X.
  function automatic [255:0] line_for(input [63:0] a);
    logic [63:0] base;
    begin
      base = {a[63:5], 5'b0};
      for (int j = 0; j < 8; j++) line_for[32*j +: 32] = base[31:0] + 4*j;
    end
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mem_done <= 1'b0;
      block    <= '0;
    end else begin
      mem_done <= 1'b0;
      if (mem_req && !mem_done) begin
        block    <= line_for(axi_addr);
        mem_done <= 1'b1;
        fills    <= fills + 1;
        check_fill_addr(axi_addr, pc);
      end
    end
  end

  task automatic fetch(input [63:0] a, input [31:0] exp);
    bit got    = 1'b0;
    int guard  = 0;
    pc = a;
    while (!got && guard < 500) begin
      @(posedge clk);
      guard = guard + 1;
      if (!stall) got = 1'b1;
    end
    if (!got) begin
      errors++;
      $display("[FAIL] icache addr=%h: no word served within 500 cycles", a);
    end else if (word !== exp) begin
      errors++;
      $display("[FAIL] icache addr=%h: got %h expected %h (wrong line served on HIT)",
               a, word, exp);
    end else begin
      $display("[ok  ] icache addr=%h -> %h", a, word);
    end
    @(posedge clk);
    pc = a + 4;
    @(posedge clk);
  endtask

  localparam [63:0] A = 64'h0000_0000;   // addr[8:5]=0 -> set 0 (correct)
  localparam [63:0] B = 64'h0000_00A0;   // addr[8:5]=5; addr[11:8]=0, same as A

  initial begin
    $display("== legacy icache index/tag alias regression: INDEX_WIDTH=%0d, TAG_WIDTH=%0d ==", W, TAGW);
    repeat (4) @(posedge clk);
    rst_n = 1'b1;

    fetch(A, A[31:0]);                                   // miss + fill
    if (fills != 1) begin errors++; $display("[FAIL] expected 1 fill after A, got %0d", fills); end

    fetch(A, A[31:0]);                                   // hit
    if (fills != 1) begin errors++; $display("[FAIL] A re-fetch refilled (%0d fills): not a hit", fills); end

    fetch(B, B[31:0]);                                   // miss + fill of a different set
    if (fills != 2) begin errors++; $display("[FAIL] expected 2 fills after B, got %0d", fills); end

    fetch(A, A[31:0]);                                   // DISCRIMINATING: hit, must still be A's line
    if (fills != 2) begin errors++; $display("[FAIL] A after B refilled (%0d fills)", fills); end

    fetch(B, B[31:0]);                                   // hit
    if (fills != 2) begin errors++; $display("[FAIL] B re-fetch refilled (%0d fills)", fills); end

    if (errors == 0 && addr_errs == 0) $display("RESULT: PASS (legacy icache, %0d fills, fill addresses decomposed correctly)", fills);
    else             $display("RESULT: FAIL (legacy icache, %0d error(s), %0d address error(s), %0d fills)", errors, addr_errs, fills);
    $finish;
  end

endmodule
