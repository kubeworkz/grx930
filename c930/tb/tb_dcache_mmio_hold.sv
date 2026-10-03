// tb_dcache_mmio_hold.sv
//
// An MMIO load's data has to survive a frozen pipeline.
//
// The D-cache services an MMIO load in MMIO_READ and releases its stall on the
// cycle the response arrives, so the load can move MEM -> WB.  If something
// else is holding the pipe on that cycle -- an I-cache fill does, through the
// hazard unit's stall_wb -- the load stays in MEM, and MMIO_RD_RETIRE waits
// there with the request deasserted until it leaves.  It kept the MMIO input
// selected onto the core's data mux for the whole wait, on the stated premise
// that the bridge's response is still valid.
//
// It is still valid on a single core.  On the four-core SoC it need not be: the
// response bus is shared (c930_mmio_arb.sv hands every core the same
// i_mmio_read_data), the request has been deasserted, and the arbiter serves
// whoever asks next.  The parked secondary cores poll CORE*_RELEASE through
// that same bridge, each every eight hundred cycles or so, and when one of
// those polls lands inside the wait the bus carries its zero -- which is what
// the load then takes to WB when the fill ends.
//
// Found by `make pta_fw PTM_B=1`: PTA_ERR_FOUND read 0x00000a80 on the bus at
// cycle 18135, an I-cache fill of the next line held the pipe until 18150, and
// the register the firmware then stored held zero.  Which load is hit depends
// only on where the code happens to fall against a cache-line boundary, so
// adding a line of C after the read made it go away.
//
// So this bench holds the D-cache to the property directly, with the MMIO side
// driven by hand as a bus that somebody else takes over:
//
//   1. the response arrives and the pipe is NOT frozen: the data is there on
//      the done cycle (the control -- this always worked);
//   2. the response arrives, the pipe IS frozen, and the bus changes under it:
//      the D-cache must go on presenting the load's own data until the load
//      leaves MEM;
//   3. the read is issued exactly once in both cases, which is what
//      MMIO_RD_RETIRE was added for and must keep doing;
//   4. a second load afterwards gets ITS data, not a stale latch.
module tb_dcache_mmio_hold;

  logic clk   = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  logic [63:0] data_from_core = 64'd0;
  logic [63:0] addr_from_core = 64'd0;
  logic        read = 1'b0, write = 1'b0;
  logic [1:0]  size = 2'b10;
  logic        stall;
  logic [63:0] data_to_core;
  logic        store_fault, load_fault, amo_fault;

  logic [63:0]  dmem_rd_addr, dmem_wr_addr, dmem_wr_data;
  logic         dmem_rd_req, dmem_wr_valid;
  logic [7:0]   dmem_wr_strobe;

  logic [63:0] mmio_rd_addr, mmio_wr_addr, mmio_wr_data;
  logic        mmio_rd_req, mmio_wr_valid;
  logic [7:0]  mmio_wr_strobe;
  logic        mmio_rd_done = 1'b0;
  logic [63:0] mmio_rd_data = 64'd0;
  logic        inv_ack;

  riscv_core_dcache_top #(
    .TAG_WIDTH (52),
    .MMIO_BASE (64'h4000_0000)
  ) u_dcache (
    .i_clk               (clk),
    .i_rst_n             (rst_n),
    .i_data_from_core    (data_from_core),
    .i_addr_from_core    (addr_from_core),
    .i_read              (read),
    .i_write             (write),
    .i_size              (size),
    .i_amo_op            (4'd0),
    .i_amo               (1'b0),
    .i_lr                (1'b0),
    .i_sc                (1'b0),
    .o_stall             (stall),
    .o_data_to_core      (data_to_core),
    .o_store_fault       (store_fault),
    .o_load_fault        (load_fault),
    .o_amo_fault         (amo_fault),
    .o_mem_read_address  (dmem_rd_addr),
    .o_mem_read_req      (dmem_rd_req),
    .i_mem_read_done     (1'b0),
    .i_block_from_axi    (256'd0),
    .i_mem_write_done    (1'b0),
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
    .i_mmio_write_done   (1'b0),
    .i_inv_valid         (1'b0),
    .i_inv_addr          (64'd0),
    .o_inv_ack           (inv_ack)
  );

  // How many times the D-cache has asked the bridge for a read.
  int   rd_issues = 0;
  logic rd_req_q  = 1'b0;
  always @(posedge clk) begin
    if (mmio_rd_req && !rd_req_q) rd_issues <= rd_issues + 1;
    rd_req_q <= mmio_rd_req;
  end

  int fails = 0;
  task automatic check(input string what, input logic ok);
    if (ok) $display("  [PASS] %s", what);
    else begin $display("  [FAIL] %s", what); fails++; end
  endtask

  // One MMIO load.  The response is `mine`, driven for the single cycle the
  // done pulse lasts, as the arbiter's per-core done is.  From the next cycle
  // the bus carries `theirs` -- another core's transaction -- and the load is
  // held in MEM for `freeze` further cycles before the pipe lets it go.
  // `seen` is what the core would have latched into WB when it left.
  task automatic mmio_load(input logic [63:0] addr, input logic [63:0] mine,
                           input logic [63:0] theirs, input int freeze,
                           output logic [63:0] seen, output logic held_ok,
                           output logic stall_ok);
    int guard;
    held_ok  = 1'b1;
    stall_ok = 1'b1;
    @(negedge clk);
    addr_from_core = addr;
    read           = 1'b1;
    guard = 0;
    while (!mmio_rd_req && guard < 50) begin @(negedge clk); guard++; end
    repeat (3) @(negedge clk);            // the bridge's own latency
    mmio_rd_data = mine;
    mmio_rd_done = 1'b1;
    #1;
    seen = data_to_core;                  // an unfrozen pipe samples here
    if (stall !== 1'b0) stall_ok = 1'b0;  // and must have been released to
    @(negedge clk);
    mmio_rd_done = 1'b0;
    mmio_rd_data = theirs;                // the bus is somebody else's now
    for (int i = 0; i < freeze; i++) begin
      #1;
      if (data_to_core !== mine) held_ok = 1'b0;
      // The pipe is released for the whole wait: the stall the load is stuck
      // behind is the I-cache's, and a D-cache that re-asserted its own would
      // deadlock against it.
      if (stall !== 1'b0) stall_ok = 1'b0;
      seen = data_to_core;                // a frozen pipe samples when it thaws
      @(negedge clk);
    end
    read = 1'b0;                          // the load leaves MEM
    repeat (4) @(negedge clk);            // drain, back to IDLE
  endtask

  logic [63:0] seen;
  logic        held_ok, stall_ok;
  int          issues0;

  initial begin
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    $display("[HOLD] an MMIO load's data across a frozen pipeline");

    // ---- 1: the control.  Nothing freezes the pipe. -----------------------
    issues0 = rd_issues;
    mmio_load(64'h4000_01F0, 64'h0000_0000_0000_0A80, 64'd0, 0,
              seen, held_ok, stall_ok);
    check("unfrozen: the load sees its data on the done cycle",
          seen === 64'h0000_0000_0000_0A80);
    check("unfrozen: the stall is released on the done cycle", stall_ok);
    check("unfrozen: the read was issued once", rd_issues - issues0 == 1);

    // ---- 2: frozen through an I-cache fill, the bus taken by another core --
    // Thirteen cycles is what the fill measured on the SoC; the property does
    // not depend on the number.
    issues0 = rd_issues;
    mmio_load(64'h4000_01F0, 64'h0000_0000_0000_0A80, 64'd0, 13,
              seen, held_ok, stall_ok);
    check("frozen: the data is held on every cycle of the wait", held_ok);
    check("frozen: what the load takes to WB is its own data, not the bus's",
          seen === 64'h0000_0000_0000_0A80);
    check("frozen: the pipe stays released while the load waits", stall_ok);
    check("frozen: the read was issued once, not replayed", rd_issues - issues0 == 1);

    // ---- 3: all ones on the bus instead of zero ---------------------------
    // Zero is what the parked cores happen to read.  A hold that only worked
    // because the other value was zero would not be a hold.
    issues0 = rd_issues;
    mmio_load(64'h4000_018C, 64'h0000_0000_0000_13C0, 64'hFFFF_FFFF_FFFF_FFFF, 5,
              seen, held_ok, stall_ok);
    check("frozen, bus all ones: held", held_ok && seen === 64'h0000_0000_0000_13C0);
    check("frozen, bus all ones: issued once", rd_issues - issues0 == 1);

    // ---- 4: the next load gets its own data, not the last one's latch -----
    issues0 = rd_issues;
    mmio_load(64'h4000_0144, 64'h0000_0000_0013_C002, 64'd0, 0,
              seen, held_ok, stall_ok);
    check("the next load, unfrozen: its own data, not the previous latch",
          seen === 64'h0000_0000_0013_C002);
    mmio_load(64'h4000_0178, 64'h0000_0000_0000_0002, 64'h0000_0000_DEAD_BEEF, 7,
              seen, held_ok, stall_ok);
    check("and the one after, frozen: held",
          held_ok && seen === 64'h0000_0000_0000_0002);
    check("two loads, two reads", rd_issues - issues0 == 2);

    if (fails == 0) $display("[PASS] tb_dcache_mmio_hold: every check");
    else            $fatal(1, "[FAIL] tb_dcache_mmio_hold: %0d checks", fails);
    $finish;
  end

  initial begin
    #200000;
    $fatal(1, "[FAIL] tb_dcache_mmio_hold: watchdog");
  end

endmodule
