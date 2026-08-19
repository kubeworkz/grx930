// tb_hazard_csrflush.sv - standalone checks for the hazard unit:
//   * the CSR flush source of flush_ex is deferred while the pipeline is
//     stalled (same rule as pcsrc),
//   * the ID-based CSR-read stall holds a dependent in ID (IF/ID + ID/EX)
//     while a CSR-read producer sits in EX/MEM/WB, bubbles the producer's
//     id_ex copy (flush_ex), and pulses stall_mem for exactly the producer's
//     first MEM cycle (csr_mem_hold drain) so the bubble-EX output cannot
//     clobber the producer's ex_mem copy. CSR read data is never forwarded
//     through the WB->EX forward (the load-use WB forward still fires).
module tb;
  logic clk = 0;
  always #5 clk = ~clk;
  logic rst_n = 0;

  logic [4:0] rs1_id, rs2_id, rs1_ex, rs2_ex, rd_ex, rd_mem, rd_wb;
  logic regwrite_mem, regwrite_wb, regwrite_ex;
  logic [1:0] resultsrc_ex;
  logic pcsrc_ex;
  logic illegal_instr, mdone, mbusy, dcache_stall, icache_stall;
  logic csr_flush_id, csr_flush_ex, csr_flush_mem, csr_flush_wb;
  logic [1:0] resultsrc_mem, resultsrc_wb;
  logic [1:0] forwarda_ex, forwardb_ex;
  logic stall_if, stall_id, stall_ex, stall_mem, stall_wb;
  logic flush_id, flush_ex, flush_mem, flush_wb;

  riscv_core_hazard_unit u (
    .i_hazard_unit_clk(clk), .i_hazard_unit_rst_n(rst_n),
    .i_hazard_unit_rs1_id(rs1_id), .i_hazard_unit_rs2_id(rs2_id),
    .i_hazard_unit_rs1_ex(rs1_ex), .i_hazard_unit_rs2_ex(rs2_ex),
    .i_hazard_unit_rd_ex(rd_ex), .i_hazard_unit_rd_mem(rd_mem),
    .i_hazard_unit_rd_wb(rd_wb),
    .i_hazard_unit_regwrite_mem(regwrite_mem), .i_hazard_unit_regwrite_wb(regwrite_wb),
    .i_hazard_unit_regwrite_ex(regwrite_ex),
    .i_hazard_unit_resultsrc_ex(resultsrc_ex), .i_hazard_unit_pcsrc_ex(pcsrc_ex),
    .i_hazard_unit_illegal_instr(illegal_instr),
    .i_hazard_unit_mdone(mdone), .i_hazard_unit_mbusy(mbusy),
    .i_hazard_unit_dcache_stall(dcache_stall), .i_hazard_unit_icache_stall(icache_stall),
    .i_hazard_unit_csr_flush_id(csr_flush_id), .i_hazard_unit_csr_flush_ex(csr_flush_ex),
    .i_hazard_unit_csr_flush_mem(csr_flush_mem), .i_hazard_unit_csr_flush_wb(csr_flush_wb),
    .i_hazard_unit_resultsrc_mem(resultsrc_mem),
    .i_hazard_unit_resultsrc_wb(resultsrc_wb),
    .o_hazard_unit_forwarda_ex(forwarda_ex), .o_hazard_unit_forwardb_ex(forwardb_ex),
    .o_hazard_unit_stall_if(stall_if), .o_hazard_unit_stall_id(stall_id),
    .o_hazard_unit_stall_ex(stall_ex), .o_hazard_unit_stall_mem(stall_mem),
    .o_hazard_unit_stall_wb(stall_wb),
    .o_hazard_unit_flush_id(flush_id), .o_hazard_unit_flush_ex(flush_ex),
    .o_hazard_unit_flush_mem(flush_mem), .o_hazard_unit_flush_wb(flush_wb)
  );

  int errors = 0;
  task check(input string what, input logic got, input logic want);
    if (got !== want) begin
      $display("[FAIL] %s: got %b want %b", what, got, want);
      errors = errors + 1;
    end
  endtask

  initial begin
    rs1_id = 0; rs2_id = 0; rs1_ex = 0; rs2_ex = 0; rd_ex = 0; rd_mem = 0; rd_wb = 0;
    regwrite_mem = 0; regwrite_wb = 0; regwrite_ex = 0; resultsrc_ex = 0; pcsrc_ex = 0;
    illegal_instr = 0; mdone = 1; mbusy = 0; dcache_stall = 0; icache_stall = 0;
    csr_flush_id = 0; csr_flush_ex = 0; csr_flush_mem = 0; csr_flush_wb = 0;
    resultsrc_mem = 0; resultsrc_wb = 0;

    @(negedge clk);
    rst_n = 1;   // release reset; the drain flop clears
    @(negedge clk);

    // Case 1: CSR flush with NO stall -> flush_ex must fire immediately.
    @(negedge clk);
    csr_flush_id = 1;  // real core drives flush_id via the CSR IF flush
    csr_flush_ex = 1;
    #1;
    check("csr flush, no stall: flush_ex", flush_ex, 1'b1);
    check("csr flush, no stall: flush_id", flush_id, 1'b1);
    @(negedge clk); csr_flush_id = 0; csr_flush_ex = 0;

    // Case 2: CSR flush DURING an icache stall -> flush_ex deferred, flush_id fires.
    @(negedge clk);
    icache_stall = 1;
    #1;
    check("icache stall: stall_if", stall_if, 1'b1);
    csr_flush_id = 1;
    csr_flush_ex = 1;
    #1;
    check("csr flush during stall: flush_ex deferred", flush_ex, 1'b0);
    check("csr flush during stall: flush_id immediate", flush_id, 1'b1);
    @(negedge clk);

    // Case 3: stall releases with csr_flush_ex still asserted -> flush_ex fires.
    icache_stall = 0;
    #1;
    check("csr flush at release: flush_ex", flush_ex, 1'b1);
    @(negedge clk); csr_flush_id = 0; csr_flush_ex = 0;

    // Case 4: pcsrc DURING a dcache stall -> flush_ex deferred (existing rule).
    @(negedge clk);
    dcache_stall = 1;
    pcsrc_ex = 1;
    #1;
    check("pcsrc during dcache stall: flush_ex deferred", flush_ex, 1'b0);
    check("pcsrc during dcache stall: flush_id immediate", flush_id, 1'b1);
    @(negedge clk);
    dcache_stall = 0;
    #1;
    check("pcsrc at release: flush_ex", flush_ex, 1'b1);
    @(negedge clk); pcsrc_ex = 0;

    // Case 5: mret (csr_flush_mem) during a mul-busy stall.
    @(negedge clk);
    mbusy = 1; mdone = 0;
    csr_flush_mem = 1;  // drives csr_flush_ex path via the csr_flush_ex input in a real core
    csr_flush_ex = 1;
    #1;
    check("mret-ish flush during mbusy: flush_ex deferred", flush_ex, 1'b0);
    @(negedge clk);
    mbusy = 0; mdone = 1;
    #1;
    check("mret-ish flush at mbusy release: flush_ex", flush_ex, 1'b1);
    @(negedge clk); csr_flush_ex = 0; csr_flush_mem = 0;

    // ------------------------------------------------------------------
    // CSR-read stall: producer csrrs x5 flows EX -> MEM -> WB while a
    // dependent in ID (rs1=x5) is held. Cycle-accurate with the drain
    // pulse (csr_mem_hold) and the id_ex bubble (flush_ex on the EX
    // cycle).
    // ------------------------------------------------------------------

    // Cycle A: producer in EX, dependent in ID -> hold IF/ID/EX, bubble id_ex.
    @(negedge clk);
    rs1_id = 5; rd_ex = 5; resultsrc_ex = 2'b11; regwrite_ex = 1;
    #1;
    check("csr producer in EX: stall_if", stall_if, 1'b1);
    check("csr producer in EX: stall_id", stall_id, 1'b1);
    check("csr producer in EX: stall_ex", stall_ex, 1'b1);
    check("csr producer in EX: stall_mem clear", stall_mem, 1'b0);
    check("csr producer in EX: stall_wb clear", stall_wb, 1'b0);
    check("csr producer in EX: flush_ex bubble", flush_ex, 1'b1);

    // Cycle B: producer advanced to MEM (id_ex bubbled); drain holds ex_mem.
    @(negedge clk);
    rd_ex = 0; resultsrc_ex = 2'b00; regwrite_ex = 0;
    rd_mem = 5; resultsrc_mem = 2'b11; regwrite_mem = 1;
    #1;
    check("csr producer in MEM: stall_if", stall_if, 1'b1);
    check("csr producer in MEM: stall_ex", stall_ex, 1'b1);
    check("csr producer in MEM: stall_mem drain", stall_mem, 1'b1);
    check("csr producer in MEM: stall_wb clear", stall_wb, 1'b0);
    check("csr producer in MEM: flush_ex clear", flush_ex, 1'b0);

    // Cycle C: drain released; producer still in MEM, advances next edge.
    @(negedge clk);
    #1;
    check("csr producer in MEM, drain off: stall_mem clear", stall_mem, 1'b0);
    check("csr producer in MEM, drain off: stall_id", stall_id, 1'b1);

    // Cycle D: producer in WB; dependent still held; no CSR forward.
    @(negedge clk);
    rd_mem = 0; resultsrc_mem = 2'b00; regwrite_mem = 0;
    rd_wb = 5; resultsrc_wb = 2'b11; regwrite_wb = 1;
    rs1_ex = 9;   // unrelated EX instruction using a different register
    #1;
    check("csr producer in WB: stall_if", stall_if, 1'b1);
    check("csr producer in WB: stall_id", stall_id, 1'b1);
    check("csr producer in WB: stall_ex", stall_ex, 1'b1);
    check("csr producer in WB: stall_wb clear", stall_wb, 1'b0);
    check("csr producer in WB: forwarda excluded", forwarda_ex, 2'b00);
    check("csr producer in WB: forwardb excluded", forwardb_ex, 2'b00);

    // Cycle E: producer left WB -> dependent releases.
    @(negedge clk);
    rd_wb = 0; resultsrc_wb = 2'b00; regwrite_wb = 0;
    #1;
    check("csr producer gone: stall_if clear", stall_if, 1'b0);
    check("csr producer gone: stall_id clear", stall_id, 1'b0);
    check("csr producer gone: stall_ex clear", stall_ex, 1'b0);

    // Case 8: LOAD producer in WB (resultsrc_wb==01) with an EX dependent ->
    // the WB->EX forward MUST still fire (the load-use path is untouched).
    @(negedge clk);
    rs1_id = 0; rd_wb = 9; resultsrc_wb = 2'b01; regwrite_wb = 1;
    rs1_ex = 9;
    #1;
    check("load producer in WB: forwarda fires", forwarda_ex, 2'b01);
    check("load producer in WB: no CSR stall", stall_id, 1'b0);
    @(negedge clk);

    // Case 9: CSR producer in MEM, dependent in ID -> held (MEM term).
    rs1_id = 7; rs1_ex = 0; rd_mem = 7; resultsrc_mem = 2'b11; regwrite_mem = 1;
    rd_wb = 0; resultsrc_wb = 2'b00; regwrite_wb = 0;
    #1;
    check("csr producer in MEM: stall_id", stall_id, 1'b1);
    check("csr producer in MEM: stall_ex", stall_ex, 1'b1);
    @(negedge clk);
    rs1_id = 0; rd_mem = 0; resultsrc_mem = 2'b00; regwrite_mem = 0;

    // Case 10 (regression guard): LOAD producer in EX (resultsrc_ex==01) with a
    // dependent in ID, WHILE dcache_stall is still asserted (the preceding
    // store/AMO still being serviced as the next producer enters EX -- the
    // exact back-to-back-memory-op pattern from the store-ordering stress).
    //
    // The load-use bubble (flush_ex) is DEFERRED by the dcache_stall guard, so
    // stall_ex must be HIGH to FREEZE the id_ex pipe this cycle. If the stall
    // detection were ever registered (one-cycle lag) the pipe would be neither
    // frozen nor bubbled and the dependent would be captured into EX -- the
    // store re-dispatch / lost-AMO corruption seen when that retime was tried.
    // The stall detection MUST stay combinational for this invariant.
    @(negedge clk);
    rs1_id = 5; rd_ex = 5; resultsrc_ex = 2'b01; regwrite_ex = 1;
    dcache_stall = 1;
    #1;
    check("load producer in EX + dcache_stall: stall_id", stall_id, 1'b1);
    check("load producer in EX + dcache_stall: stall_ex FREEZES id_ex", stall_ex, 1'b1);
    check("load producer in EX + dcache_stall: flush_ex deferred", flush_ex, 1'b0);
    check("load producer in EX + dcache_stall: stall_mem", stall_mem, 1'b1);
    @(negedge clk);
    dcache_stall = 0;
    rd_ex = 0; resultsrc_ex = 2'b00; regwrite_ex = 0; rs1_id = 0;

    if (errors == 0)
      $display("[PASS] hazard CSR-flush deferral + CSR-read stall checks passed");
    else
      $display("[FAIL] %0d checks failed", errors);
    $finish;
  end
endmodule
