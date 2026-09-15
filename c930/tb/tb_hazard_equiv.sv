// tb_hazard_equiv.sv - dual-DUT equivalence gate for the forwarding-select
// retiming in riscv_core_hazard_unit.
//
//   ref : riscv_core_hazard_unit_ref   (pristine combinational selects)
//   dut : riscv_core_hazard_unit       (registered selects, shadow next-state)
//
// Both units see IDENTICAL ports. The pipe register fields the compares read
// (rs1_ex/rs2_ex from ID/EX, rd_mem/regwrite_mem/resultsrc_mem from EX/MEM,
// rd_wb/regwrite_wb/resultsrc_wb from MEM/WB) are modeled TB-side with the
// exact riscv_core_pipe behaviour f(clr, en, D), driven by the SHARED
// flush/stall outputs (asserted equal between dut and ref every cycle) and
// free random D stimulus. Free stimulus is a deliberate superset of what the
// real cascade can generate; the equivalence invariant
//
//     dut_forward@t == ref_forward@t   (and all stall/flush outputs equal)
//
// must therefore hold for EVERY input sequence if the shadow next-state
// replication (pipe f(clr,en,D)) is exact.
// ============================================================================

module tb;
  logic clk = 0;
  always #5 clk = ~clk;
  logic rst_n = 0;

  // ---- stimulus: pipe D fields (free random) + external stall/flush sources
  logic [4:0] rs1_id_s, rs2_id_s;              // -> ID/EX pipes (rs1_ex, rs2_ex)
  logic [4:0] rd_ex_s;  logic regwrite_ex_s;  logic [1:0] resultsrc_ex_s; // -> EX/MEM pipes
  logic [4:0] rd_mem_s; logic regwrite_mem_s; logic [1:0] resultsrc_mem_s; // -> MEM/WB pipes
  logic [4:0] rd_wb_s_dummy;                   // (rd_wb has no further consumer; kept for symmetry)
  logic pcsrc_ex, illegal_instr, mdone, mbusy, dcache_stall, icache_stall;
  logic csr_flush_id, csr_flush_ex, csr_flush_mem, csr_flush_wb;
  logic [63:0] pc_id_s, pc_ex_s;

  // ---- shared pipe-model outputs (drives both DUTs)
  logic [4:0] rs1_ex, rs2_ex;
  logic [4:0] rd_mem, rd_wb;
  logic regwrite_mem, regwrite_wb;
  logic [1:0] resultsrc_mem, resultsrc_wb;
  logic [4:0] rd_ex;                            // id_ex rd pipe output (feeds ex_mem D + ports)

  // dut flush/stall (drives the TB pipe models)
  logic dut_flush_id, dut_flush_ex, dut_flush_mem, dut_flush_wb;
  logic dut_stall_if, dut_stall_id, dut_stall_ex, dut_stall_mem, dut_stall_wb;

  // pipe next-state helper (riscv_core_pipe semantics)
  function automatic logic [4:0] p5_next(input logic clr, input logic hold,
                                         input logic [4:0] cur, input logic [4:0] d);
    p5_next = clr ? 5'b0 : (hold ? cur : d);
  endfunction

  // ---- REAL production pipe registers (riscv_core_pipe) model the fields
  // the compares read, driven by the shared flush/stall outputs and random D.
  // The dut's shadow next-state must match these EXACTLY at every edge.
  riscv_core_pipe #(.W_PIPE_BUS(5)) pipe_rs1_ex (.i_pipe_clk(clk), .i_pipe_rst_n(rst_n), .i_pipe_clr(dut_flush_ex),  .i_pipe_en_n(dut_stall_ex),  .i_pipe_in(rs1_id_s),       .o_pipe_out(rs1_ex));
  riscv_core_pipe #(.W_PIPE_BUS(5)) pipe_rs2_ex (.i_pipe_clk(clk), .i_pipe_rst_n(rst_n), .i_pipe_clr(dut_flush_ex),  .i_pipe_en_n(dut_stall_ex),  .i_pipe_in(rs2_id_s),       .o_pipe_out(rs2_ex));
  riscv_core_pipe #(.W_PIPE_BUS(5)) pipe_rd_ex  (.i_pipe_clk(clk), .i_pipe_rst_n(rst_n), .i_pipe_clr(dut_flush_ex),  .i_pipe_en_n(dut_stall_ex),  .i_pipe_in(rd_ex_s),        .o_pipe_out(rd_ex));
  riscv_core_pipe #(.W_PIPE_BUS(5)) pipe_rd_mem (.i_pipe_clk(clk), .i_pipe_rst_n(rst_n), .i_pipe_clr(dut_flush_mem), .i_pipe_en_n(dut_stall_mem), .i_pipe_in(rd_ex),            .o_pipe_out(rd_mem)); // hardware: ex_mem D = id_ex rd pipe output
  riscv_core_pipe #(.W_PIPE_BUS(1)) pipe_rw_mem (.i_pipe_clk(clk), .i_pipe_rst_n(rst_n), .i_pipe_clr(dut_flush_mem), .i_pipe_en_n(dut_stall_mem), .i_pipe_in(regwrite_ex_s),  .o_pipe_out(regwrite_mem));
  riscv_core_pipe #(.W_PIPE_BUS(2)) pipe_rs_mem (.i_pipe_clk(clk), .i_pipe_rst_n(rst_n), .i_pipe_clr(dut_flush_mem), .i_pipe_en_n(dut_stall_mem), .i_pipe_in(resultsrc_ex_s), .o_pipe_out(resultsrc_mem));
  riscv_core_pipe #(.W_PIPE_BUS(5)) pipe_rd_wb  (.i_pipe_clk(clk), .i_pipe_rst_n(rst_n), .i_pipe_clr(dut_flush_wb),  .i_pipe_en_n(dut_stall_wb),  .i_pipe_in(rd_mem),         .o_pipe_out(rd_wb));  // hardware: mem_wb D = ex_mem rd pipe output
  riscv_core_pipe #(.W_PIPE_BUS(1)) pipe_rw_wb  (.i_pipe_clk(clk), .i_pipe_rst_n(rst_n), .i_pipe_clr(dut_flush_wb),  .i_pipe_en_n(dut_stall_wb),  .i_pipe_in(regwrite_mem),   .o_pipe_out(regwrite_wb));
  riscv_core_pipe #(.W_PIPE_BUS(2)) pipe_rs_wb  (.i_pipe_clk(clk), .i_pipe_rst_n(rst_n), .i_pipe_clr(dut_flush_wb),  .i_pipe_en_n(dut_stall_wb),  .i_pipe_in(resultsrc_mem),  .o_pipe_out(resultsrc_wb));

  // ---- DUT (retimed) and REF (pristine) instances, identical wiring
  logic [1:0] dut_fa, dut_fb, ref_fa, ref_fb;
  logic ref_flush_id, ref_flush_ex, ref_flush_mem, ref_flush_wb;
  logic ref_stall_if, ref_stall_id, ref_stall_ex, ref_stall_mem, ref_stall_wb;

  riscv_core_hazard_unit u_dut (
    .i_hazard_unit_clk(clk), .i_hazard_unit_rst_n(rst_n),
    .i_hazard_unit_rs1_id(rs1_id_s), .i_hazard_unit_rs2_id(rs2_id_s),
    .i_hazard_unit_rs1_ex(rs1_ex), .i_hazard_unit_rs2_ex(rs2_ex),
    .i_hazard_unit_rd_ex(rd_ex), .i_hazard_unit_rd_mem(rd_mem),
    .i_hazard_unit_rd_wb(rd_wb),
    .i_hazard_unit_regwrite_mem(regwrite_mem), .i_hazard_unit_regwrite_wb(regwrite_wb),
    .i_hazard_unit_regwrite_ex(regwrite_ex_s),
    .i_hazard_unit_resultsrc_ex(resultsrc_ex_s), .i_hazard_unit_pcsrc_ex(pcsrc_ex),
    .i_hazard_unit_illegal_instr(illegal_instr),
    .i_hazard_unit_mdone(mdone), .i_hazard_unit_mbusy(mbusy),
    .i_hazard_unit_dcache_stall(dcache_stall), .i_hazard_unit_icache_stall(icache_stall),
    .i_hazard_unit_csr_flush_id(csr_flush_id), .i_hazard_unit_csr_flush_ex(csr_flush_ex),
    .i_hazard_unit_csr_flush_mem(csr_flush_mem), .i_hazard_unit_csr_flush_wb(csr_flush_wb),
    .i_hazard_unit_resultsrc_mem(resultsrc_mem), .i_hazard_unit_resultsrc_wb(resultsrc_wb),
    .i_hazard_unit_pc_id(pc_id_s), .i_hazard_unit_pc_ex(pc_ex_s),
    .o_hazard_unit_forwarda_ex(dut_fa), .o_hazard_unit_forwardb_ex(dut_fb),
    .o_hazard_unit_stall_if(dut_stall_if), .o_hazard_unit_stall_id(dut_stall_id),
    .o_hazard_unit_stall_ex(dut_stall_ex), .o_hazard_unit_stall_mem(dut_stall_mem),
    .o_hazard_unit_stall_wb(dut_stall_wb),
    .o_hazard_unit_flush_id(dut_flush_id), .o_hazard_unit_flush_ex(dut_flush_ex),
    .o_hazard_unit_flush_mem(dut_flush_mem), .o_hazard_unit_flush_wb(dut_flush_wb)
  );

  riscv_core_hazard_unit_ref ref_u (
    .i_hazard_unit_clk(clk), .i_hazard_unit_rst_n(rst_n),
    .i_hazard_unit_rs1_id(rs1_id_s), .i_hazard_unit_rs2_id(rs2_id_s),
    .i_hazard_unit_rs1_ex(rs1_ex), .i_hazard_unit_rs2_ex(rs2_ex),
    .i_hazard_unit_rd_ex(rd_ex), .i_hazard_unit_rd_mem(rd_mem),
    .i_hazard_unit_rd_wb(rd_wb),
    .i_hazard_unit_regwrite_mem(regwrite_mem), .i_hazard_unit_regwrite_wb(regwrite_wb),
    .i_hazard_unit_regwrite_ex(regwrite_ex_s),
    .i_hazard_unit_resultsrc_ex(resultsrc_ex_s), .i_hazard_unit_pcsrc_ex(pcsrc_ex),
    .i_hazard_unit_illegal_instr(illegal_instr),
    .i_hazard_unit_mdone(mdone), .i_hazard_unit_mbusy(mbusy),
    .i_hazard_unit_dcache_stall(dcache_stall), .i_hazard_unit_icache_stall(icache_stall),
    .i_hazard_unit_csr_flush_id(csr_flush_id), .i_hazard_unit_csr_flush_ex(csr_flush_ex),
    .i_hazard_unit_csr_flush_mem(csr_flush_mem), .i_hazard_unit_csr_flush_wb(csr_flush_wb),
    .i_hazard_unit_resultsrc_mem(resultsrc_mem), .i_hazard_unit_resultsrc_wb(resultsrc_wb),
    .i_hazard_unit_pc_id(pc_id_s), .i_hazard_unit_pc_ex(pc_ex_s),
    .o_hazard_unit_forwarda_ex(ref_fa), .o_hazard_unit_forwardb_ex(ref_fb),
    .o_hazard_unit_stall_if(ref_stall_if), .o_hazard_unit_stall_id(ref_stall_id),
    .o_hazard_unit_stall_ex(ref_stall_ex), .o_hazard_unit_stall_mem(ref_stall_mem),
    .o_hazard_unit_stall_wb(ref_stall_wb),
    .o_hazard_unit_flush_id(ref_flush_id), .o_hazard_unit_flush_ex(ref_flush_ex),
    .o_hazard_unit_flush_mem(ref_flush_mem), .o_hazard_unit_flush_wb(ref_flush_wb)
  );

  // ---- field-level shadow-replication checker: sample the dut's shadow
  // next-values at the stable mid-cycle point, then compare them with the
  // REAL pipe outputs after the edge settles. A mismatch here pins the
  // divergence to one field with full stimulus context.
  logic [4:0] s_rs1x, s_rs2x, s_rdm, s_rdw;
  logic       s_rwm, s_rww;
  logic [1:0] s_rsm, s_rsw;
  logic       s_valid = 1'b0;
  // Sample the shadow combinational next-values 4 ns after the negedge:
  // 1 ns before the posedge, when flush/stall/D hold exactly the pre-edge
  // values the dut's forwarding flop captures. (A same-negedge sample would
  // race the stimulus block.)
  always @(negedge clk) begin
    #4;
    s_rs1x = u_dut.rs1_ex_next;        s_rs2x = u_dut.rs2_ex_next;
    s_rdm  = u_dut.rd_mem_next;        s_rdw  = u_dut.rd_wb_next;
    s_rwm  = u_dut.regwrite_mem_next;  s_rww  = u_dut.regwrite_wb_next;
    s_rsm  = u_dut.resultsrc_mem_next; s_rsw  = u_dut.resultsrc_wb_next;
    s_valid = rst_n;
  end
  int shadow_errs = 0;
  always @(posedge clk) begin
    #1; // let NBAs settle
    if (s_valid && shadow_errs < 8) begin
      if (s_rs1x !== rs1_ex || s_rs2x !== rs2_ex || s_rdm !== rd_mem ||
          s_rdw !== rd_wb  || s_rwm !== regwrite_mem || s_rww !== regwrite_wb ||
          s_rsm !== resultsrc_mem || s_rsw !== resultsrc_wb) begin
        $display("[SHADOW-MISMATCH] %0t rs1x s=%0d h=%0d rs2x s=%0d h=%0d rdm s=%0d h=%0d rdw s=%0d h=%0d rwm s=%b h=%b rww s=%b h=%b rsm s=%b h=%b rsw s=%b h=%b | stim rs1_id=%0d rs2_id=%0d rd_ex=%0d rd_mem=%0d | ctl ex f=%b s=%b mem f=%b s=%b wb f=%b s=%b",
                 $time, s_rs1x, rs1_ex, s_rs2x, rs2_ex, s_rdm, rd_mem, s_rdw, rd_wb,
                 s_rwm, regwrite_mem, s_rww, regwrite_wb, s_rsm, resultsrc_mem, s_rsw, resultsrc_wb,
                 rs1_id_s, rs2_id_s, rd_ex_s, rd_mem_s,
                 dut_flush_ex, dut_stall_ex, dut_flush_mem, dut_stall_mem, dut_flush_wb, dut_stall_wb);
        shadow_errs = shadow_errs + 1;
      end
    end
  end

  // ---- stream checker state
  int errors = 0;
  longint unsigned cycles = 0, fwd_events = 0;

  // 3-cycle history for first-failure forensics
  logic [4:0] h_rs1_id [3]; logic [4:0] h_rd_ex [3]; logic h_rw_ex [3]; logic [1:0] h_rs_ex [3];
  logic [4:0] h_rd_mem [3]; logic h_rw_mem [3]; logic [1:0] h_rs_mem [3];
  logic h_fx [3]; logic h_sm [3]; logic h_fm [3]; logic h_sw [3]; logic h_fw [3];
  logic h_se [3]; logic h_fe [3];
  logic [4:0] h_rs1x [3]; logic [4:0] h_rdm [3]; logic [4:0] h_rdw [3];
  logic h_rwm [3]; logic h_rww [3]; logic [1:0] h_rsm [3]; logic [1:0] h_rsw [3];
  logic [1:0] h_dfa [3]; logic [1:0] h_rfa [3];
  int hi = 0;

  task snap;
    h_rs1_id[hi] = rs1_id_s; h_rd_ex[hi] = rd_ex_s; h_rw_ex[hi] = regwrite_ex_s; h_rs_ex[hi] = resultsrc_ex_s;
    h_rd_mem[hi] = rd_mem_s; h_rw_mem[hi] = regwrite_mem_s; h_rs_mem[hi] = resultsrc_mem_s;
    h_fx[hi] = dut_flush_ex; h_se[hi] = dut_stall_ex; h_fe[hi] = dut_flush_ex;
    h_sm[hi] = dut_stall_mem; h_fm[hi] = dut_flush_mem;
    h_sw[hi] = dut_stall_wb; h_fw[hi] = dut_flush_wb;
    h_rs1x[hi] = rs1_ex; h_rdm[hi] = rd_mem; h_rdw[hi] = rd_wb;
    h_rwm[hi] = regwrite_mem; h_rww[hi] = regwrite_wb; h_rsm[hi] = resultsrc_mem; h_rsw[hi] = resultsrc_wb;
    h_dfa[hi] = dut_fa; h_rfa[hi] = ref_fa;
    hi = (hi == 2) ? 0 : hi + 1;
  endtask

  task dump_history;
    int k;
    $display("---- history (oldest first) ----");
    for (int j = 2; j >= 0; j--) begin
      k = (hi + j) % 3;
      $display("cyc-%0d: stim rs1_id=%0d rd_ex=%0d rw_ex=%0d rs_ex=%b rd_mem=%0d rw_mem=%0d rs_mem=%b | f/e/s ex=%b/%b/%b mem=%b/%b wb=%b/%b | model rs1x=%0d rdm=%0d rdw=%0d rwm=%0d rww=%0d rsm=%b rsw=%b | fa d=%b r=%b",
               j-2, h_rs1_id[k], h_rd_ex[k], h_rw_ex[k], h_rs_ex[k], h_rd_mem[k], h_rw_mem[k], h_rs_mem[k],
               h_fe[k], 1'b0, h_se[k], h_fm[k], h_sm[k], h_fw[k], h_sw[k],
               h_rs1x[k], h_rdm[k], h_rdw[k], h_rwm[k], h_rww[k], h_rsm[k], h_rsw[k], h_dfa[k], h_rfa[k]);
    end
  endtask

  task check(input string what);
    if (dut_fa !== ref_fa || dut_fb !== ref_fb) begin
      if (errors < 20)
        $display("[FAIL] %0t %s: fa dut=%b ref=%b fb dut=%b ref=%b (rs1x=%0d rs2x=%0d rdm=%0d rdw=%0d rwm=%0d rww=%0d)",
                 $time, what, dut_fa, ref_fa, dut_fb, ref_fb,
                 rs1_ex, rs2_ex, rd_mem, rd_wb, regwrite_mem, regwrite_wb);
      if (errors == 0) dump_history();
      errors = errors + 1;
    end
    if (dut_stall_if !== ref_stall_if || dut_stall_id !== ref_stall_id ||
        dut_stall_ex !== ref_stall_ex || dut_stall_mem !== ref_stall_mem ||
        dut_stall_wb !== ref_stall_wb) begin
      if (errors < 20)
        $display("[FAIL] %0t %s: stall mismatch dut(%b%b%b%b%b) ref(%b%b%b%b%b)",
                 $time, what, dut_stall_if, dut_stall_id, dut_stall_ex, dut_stall_mem, dut_stall_wb,
                 ref_stall_if, ref_stall_id, ref_stall_ex, ref_stall_mem, ref_stall_wb);
      errors = errors + 1;
    end
    if (dut_flush_id !== ref_flush_id || dut_flush_ex !== ref_flush_ex ||
        dut_flush_mem !== ref_flush_mem || dut_flush_wb !== ref_flush_wb) begin
      if (errors < 20)
        $display("[FAIL] %0t %s: flush mismatch", $time, what);
      errors = errors + 1;
    end
  endtask

  // register-value randomizer: small pool so 5-bit compares collide often
  function automatic logic [4:0] rnd_reg();
    rnd_reg = $random & 7; // 0..7 -> ~1/8 match rate between independent fields
  endfunction

  initial begin
    rs1_id_s = 0; rs2_id_s = 0;
    rd_ex_s = 0; regwrite_ex_s = 0; resultsrc_ex_s = 0;
    rd_mem_s = 0; regwrite_mem_s = 0; resultsrc_mem_s = 0;
    pcsrc_ex = 0; illegal_instr = 0; mdone = 1; mbusy = 0;
    dcache_stall = 0; icache_stall = 0;
    csr_flush_id = 0; csr_flush_ex = 0; csr_flush_mem = 0; csr_flush_wb = 0;
    pc_id_s = 0; pc_ex_s = 0;

    repeat (4) @(negedge clk);
    rst_n = 1;
    @(negedge clk);

    // randomized phase. Correlated stimulus models the real producer->consumer
    // adjacency: the id_ex rd pipe output (rd_ex) is what enters rd_mem next
    // cycle, so an ID source equal to rd_ex creates an rs_ex==rd_mem match at
    // the next edge -- a live MEM->EX forward (modulo flush/stall interference,
    // which is exactly what we want to stress).
    for (int i = 0; i < 300000; i++) begin
      rd_ex_s  = rnd_reg(); rd_mem_s = rnd_reg();
      rs1_id_s = ($random % 10) < 4 ? rd_ex    : rnd_reg();
      rs2_id_s = ($random % 10) < 4 ? rd_ex    : rnd_reg();
      regwrite_ex_s  = ($random % 10) < 7;
      regwrite_mem_s = ($random % 10) < 7;
      resultsrc_ex_s  = ($random % 100) < 70 ? 2'b00 : (($random % 2) ? 2'b01 : 2'b11);
      resultsrc_mem_s = ($random % 100) < 70 ? 2'b00 : (($random % 2) ? 2'b01 : 2'b11);
      pcsrc_ex      = ($random % 100) < 8;
      dcache_stall  = ($random % 100) < 12;
      icache_stall  = ($random % 100) < 8;
      mbusy         = ($random % 100) < 6;
      mdone         = !mbusy || (($random % 100) < 20);
      csr_flush_id  = ($random % 100) < 6;
      csr_flush_ex  = ($random % 100) < 6;
      csr_flush_mem = ($random % 100) < 4;
      csr_flush_wb  = ($random % 100) < 3;
      pc_id_s = {$random, $random};
      pc_ex_s = ($random % 100) < 30 ? pc_id_s : {$random, $random};
      @(negedge clk);
      check("rand");
      snap;
      cycles++;
      if (dut_fa != 2'b00 || dut_fb != 2'b00) fwd_events++;
      if (errors > 50) begin
        $display("[FAIL] too many errors, aborting");
        $finish;
      end
    end

    if (errors == 0)
      $display("[PASS] tb_hazard_equiv: %0d cycles, %0d forward-active cycles, all outputs bit-equal",
               cycles, fwd_events);
    else
      $display("[FAIL] tb_hazard_equiv: %0d errors over %0d cycles", errors, cycles);
    $finish;
  end
endmodule
