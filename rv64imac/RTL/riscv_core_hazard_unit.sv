module riscv_core_hazard_unit
(

    // Clock / reset (for the one-cycle CSR-dependency stall latch)
    input  logic i_hazard_unit_clk,
    input  logic i_hazard_unit_rst_n,

    // RV64I Detection inputs
    input logic [4:0] i_hazard_unit_rs1_id,
    input logic [4:0] i_hazard_unit_rs2_id,
    input logic [4:0] i_hazard_unit_rs1_ex,
    input logic [4:0] i_hazard_unit_rs2_ex,
    input logic [4:0] i_hazard_unit_rd_ex,
    input logic [4:0] i_hazard_unit_rd_mem,
    input logic [4:0] i_hazard_unit_rd_wb,

    // Control signals inputs
    input logic i_hazard_unit_regwrite_mem,
    input logic i_hazard_unit_regwrite_wb,
    input logic i_hazard_unit_regwrite_ex,
    input logic [1:0] i_hazard_unit_resultsrc_ex,
    input logic i_hazard_unit_pcsrc_ex,

    // C Extension requests
    input logic i_hazard_unit_illegal_instr,

    // M Extension requests
    input logic i_hazard_unit_mdone,
    input logic i_hazard_unit_mbusy,

    // Caches requests
    input logic i_hazard_unit_dcache_stall,
    input logic i_hazard_unit_icache_stall,

    // Forwarding outputs
    output logic [1:0] o_hazard_unit_forwarda_ex,
    output logic [1:0] o_hazard_unit_forwardb_ex,

    // Stall outputs
    output logic o_hazard_unit_stall_if,
    output logic o_hazard_unit_stall_id,
    output logic o_hazard_unit_stall_ex,
    output logic o_hazard_unit_stall_mem,
    output logic o_hazard_unit_stall_wb,

    // Flush outputs
    output logic o_hazard_unit_flush_id,
    output logic o_hazard_unit_flush_ex,
    output logic o_hazard_unit_flush_mem,
    output logic o_hazard_unit_flush_wb,

    // CSR-dependency stall operand hold: while the one-cycle stall holds the
    // dependent instruction in EX, an operand whose producer sits in WB loses
    // its WB->EX forward on the release cycle (only EX/MEM are frozen). The
    // top captures that operand's value at the stall edge (hold_a/b_en) and
    // reselects it during the release window (csr_stall_prev). The operand
    // produced by the CSR read itself is NOT held - it is stale at the stall
    // edge and arrives via the WB->EX forward once the producer reaches WB.
    output logic o_hazard_unit_csr_hold_a_en,
    output logic o_hazard_unit_csr_hold_b_en,
    output logic o_hazard_unit_csr_stall_prev,
    // pcsrc_gate: while the CSR-dependency stall pulse holds the dependent in
    // EX, a branch/jump in EX cannot resolve (its stalled operand is stale), so
    // any pcsrc_ex asserted then is spurious and must not redirect the fetch
    // PC. (The load-use stall never holds a stale branch in EX: it holds the
    // dependent in ID and bubbles EX, so pcsrc_ex during it is always
    // legitimate.)
    output logic o_hazard_unit_pcsrc_gate,

    //CSR inputs
    input  logic i_hazard_unit_csr_flush_id,
    input  logic i_hazard_unit_csr_flush_ex,
    input  logic i_hazard_unit_csr_flush_mem,
    input  logic i_hazard_unit_csr_flush_wb,
    // MEM-stage result source: resultsrc==2'b11 (CSR read data) only exists
    // at WB, so a dependent EX instruction must not MEM-forward the producer's
    // (garbage) ALU result and must instead stall until the producer reaches WB.
    input  logic [1:0] i_hazard_unit_resultsrc_mem
);

// Internals
logic mstall_detection;
logic icache_stall_detection;
logic dcache_stall_detection;
logic csr_stall_detection;
logic csr_dep_rs1;
logic csr_dep_rs2;
logic csr_stall_prev;
logic csr_stall_active;
logic load_stall_detection;
logic load_dep_rs1;
logic load_dep_rs2;
logic load_in_ex;
logic load_in_mem;

// A CSR read in MEM whose rd matches an EX-stage source needs the producer to
// reach WB before the consumer can compute. The stall must last exactly one
// cycle: freezing the EX/MEM pipe leaves the producer's stale data in MEM,
// which would otherwise keep re-triggering the stall forever. csr_stall_active
// pulses only on the first cycle of the dependency, so the producer advances
// MEM->WB (stall_wb stays clear) and the WB->EX forward supplies the value on
// the release cycle.
always_ff @(posedge i_hazard_unit_clk or negedge i_hazard_unit_rst_n)
begin
    if (!i_hazard_unit_rst_n)
        csr_stall_prev <= 1'b0;
    // Only advance the one-cycle-pulse tracker when the pipeline can actually
    // move. If a cache fill (or the M extension) holds the pipeline during the
    // CSR-dependency window, the CSR producer cannot advance MEM->WB, so the
    // pulse must re-fire when the other stall releases -- otherwise the pulse
    // is consumed invisibly during the freeze and the dependent instruction
    // advances with a stale operand (the WB->EX forward never activates). The
    // icache's registered-read hit stall makes this overlap common.
    else if (!mstall_detection && !icache_stall_detection && !dcache_stall_detection)
        csr_stall_prev <= csr_stall_detection;
end

assign csr_stall_active = csr_stall_detection && !csr_stall_prev;

//------------------------------Forwarding------------------------------\\

always_comb 
begin : forwarding_proc

    // A CSR read (resultsrc == 2'b11) produces its value at WB, not at MEM:
    // its MEM-stage ALU result is unrelated garbage, so the MEM->EX forward
    // must not fire for it. The matching stall (csr_stall_detection below)
    // holds the dependent in EX until the producer reaches WB, where the
    // WB->EX forward supplies the CSR read data.
    //
    // The same applies to a read-data producer (resultsrc == 2'b01: load, AMO,
    // LR, SC). Its MEM-stage ALU result is the effective ADDRESS, and the
    // dcache read data is not forwarded to EX (the load-use stall below holds
    // the dependent until the producer reaches WB, where the registered
    // read-data pipe supplies the value). Excluding 2'b01 also prevents the
    // stale MEM forward from firing on the stall-release cycle, when the
    // frozen ex_mem pipe still shows the producer's rd but the value now
    // lives in WB.
    if ((i_hazard_unit_rs1_ex == i_hazard_unit_rd_mem) && i_hazard_unit_regwrite_mem && (i_hazard_unit_rs1_ex != 5'b0) && (i_hazard_unit_resultsrc_mem != 2'b11) && (i_hazard_unit_resultsrc_mem != 2'b01))
    begin
        o_hazard_unit_forwarda_ex = 2'b10;
    end
    else if ((i_hazard_unit_rs1_ex == i_hazard_unit_rd_wb) && i_hazard_unit_regwrite_wb && (i_hazard_unit_rs1_ex != 5'b0)) 
    begin
        o_hazard_unit_forwarda_ex = 2'b01;
    end
    else 
    begin
        o_hazard_unit_forwarda_ex = 2'b00;
    end
    
    // Forwarding SrcB
    if ((i_hazard_unit_rs2_ex == i_hazard_unit_rd_mem) && i_hazard_unit_regwrite_mem && (i_hazard_unit_rs2_ex != 5'b0) && (i_hazard_unit_resultsrc_mem != 2'b11) && (i_hazard_unit_resultsrc_mem != 2'b01))
    begin
        o_hazard_unit_forwardb_ex = 2'b10;
    end
    else if ((i_hazard_unit_rs2_ex == i_hazard_unit_rd_wb) && i_hazard_unit_regwrite_wb && (i_hazard_unit_rs2_ex != 5'b0)) 
    begin
        o_hazard_unit_forwardb_ex = 2'b01;
    end
    else 
    begin
        o_hazard_unit_forwardb_ex = 2'b00;
    end

end

//---------------------------------Stall---------------------------------\\

always_comb 
begin : stall_proc
    mstall_detection        = (i_hazard_unit_mbusy && !i_hazard_unit_mdone);
    icache_stall_detection  = i_hazard_unit_icache_stall;
    dcache_stall_detection  = i_hazard_unit_dcache_stall;
    // A CSR read in MEM whose rd matches an EX-stage source: the value only
    // exists at WB, so the consumer must be held in EX (its operands in the
    // id_ex pipe) until the producer advances MEM->WB. stall_wb stays clear so
    // the producer is not frozen (it advances MEM->WB, where the WB->EX
    // forward supplies the CSR read data on the release cycle). The IF/ID
    // stages freeze harmlessly for the single cycle (csr_stall_active is a
    // one-cycle pulse).
    csr_dep_rs1 = (i_hazard_unit_resultsrc_mem == 2'b11) && i_hazard_unit_regwrite_mem &&
                  (i_hazard_unit_rs1_ex == i_hazard_unit_rd_mem) && (i_hazard_unit_rs1_ex != 5'b0);
    csr_dep_rs2 = (i_hazard_unit_resultsrc_mem == 2'b11) && i_hazard_unit_regwrite_mem &&
                  (i_hazard_unit_rs2_ex == i_hazard_unit_rd_mem) && (i_hazard_unit_rs2_ex != 5'b0);
    csr_stall_detection = csr_dep_rs1 || csr_dep_rs2;
    // Load-use hazard (ID-based). A read-data producer (resultsrc == 2'b01:
    // load/AMO/LR/SC) has its value only at WB: the load data is sampled from
    // the dcache at the MEM->WB edge. A dependent in ID is therefore held in
    // ID (level-based) until the producer reaches WB, where the registered
    // WB->EX forward (mem_wb_pipe_read_data -> result_wb) supplies the value.
    // This replaces the old combinational MEM->EX load forward, which put the
    // dcache address->data chain (tag/valid decode, word select, MMIO decode)
    // on the EX critical path.
    //
    // The producer is NEVER held by this stall: stall_mem/wb stay clear, so it
    // flows EX->MEM->WB exactly as in the unstalled flow and the dcache's
    // registered-read data window is never disturbed (an earlier EX-based
    // pulse that held the load in MEM made the dcache re-enter its read path
    // and corrupt the data). The stall is level-based while the producer is in
    // EX, or in MEM while the dcache is still servicing it (dcache_stall); the
    // dcache releases its stall on LOAD_DONE - the cycle its registered data
    // is valid - and the load-use stall releases with it, so the dependent
    // enters EX exactly when the producer is in WB and the WB->EX forward is
    // live. For a hit that is one stall cycle in EX plus the dcache's own
    // read cycle; a miss or MMIO access simply extends the dcache_stall term.
    load_in_ex  = (i_hazard_unit_resultsrc_ex == 2'b01) && i_hazard_unit_regwrite_ex;
    load_in_mem = (i_hazard_unit_resultsrc_mem == 2'b01) && i_hazard_unit_regwrite_mem;
    load_dep_rs1 = (((load_in_ex) && (i_hazard_unit_rs1_id == i_hazard_unit_rd_ex)) ||
                    ((load_in_mem) && i_hazard_unit_dcache_stall && (i_hazard_unit_rs1_id == i_hazard_unit_rd_mem))) &&
                   (i_hazard_unit_rs1_id != 5'b0);
    load_dep_rs2 = (((load_in_ex) && (i_hazard_unit_rs2_id == i_hazard_unit_rd_ex)) ||
                    ((load_in_mem) && i_hazard_unit_dcache_stall && (i_hazard_unit_rs2_id == i_hazard_unit_rd_mem))) &&
                   (i_hazard_unit_rs2_id != 5'b0);
    load_stall_detection = load_dep_rs1 || load_dep_rs2;
    o_hazard_unit_stall_if  = mstall_detection || icache_stall_detection || dcache_stall_detection || csr_stall_active || load_stall_detection;
    o_hazard_unit_stall_id  = mstall_detection || icache_stall_detection || dcache_stall_detection || csr_stall_active || load_stall_detection;
    // The ID/EX pipe must also hold while the instruction cache is filling or
    // a load-use is pending: if only IF/ID is stalled, the instruction stuck
    // in ID would be re-captured into EX every cycle. (The load-use stall also
    // flushes the id_ex pipe to a bubble while the producer sits in EX - see
    // flush_proc - so the producer is never re-executed in EX while it flows
    // EX->MEM->WB.) stall_mem/wb stay clear for the load-use stall so the
    // producer advances and its registered data window is undisturbed.
    o_hazard_unit_stall_ex  = mstall_detection || icache_stall_detection || dcache_stall_detection || csr_stall_active || load_stall_detection;
    o_hazard_unit_stall_mem = mstall_detection || icache_stall_detection || dcache_stall_detection || csr_stall_active;
    // Freeze the MEM/WB pipe while either cache (or an MMIO access via the
    // dcache) is stalled: if a producer (e.g. li/lui feeding a store's data)
    // leaves WB while its consumer is held in EX, the WB->EX forward drops and
    // the consumer captures the stale pre-write register value into the
    // store-data pipe. Holding WB keeps the forward source live until the stall
    // releases, so the consumer latches the forwarded value. The CSR- and
    // load-use-dependency stalls deliberately exclude stall_wb: the producer
    // must advance MEM->WB for its value to become available.
    o_hazard_unit_stall_wb  = mstall_detection || icache_stall_detection || dcache_stall_detection;

    // Capture the operand NOT produced by the CSR read. At the stall edge its
    // value is correct (its producer is in WB and the WB->EX forward is live,
    // or it is an already-committed register value); on the release cycle that
    // producer has left WB, so the captured value must be reselected. When
    // both sources depend on the CSR read neither is held - both forward from
    // WB on the release cycle.
    o_hazard_unit_csr_hold_a_en = csr_stall_active && csr_dep_rs2 && !csr_dep_rs1;
    o_hazard_unit_csr_hold_b_en = csr_stall_active && csr_dep_rs1 && !csr_dep_rs2;
    o_hazard_unit_csr_stall_prev = csr_stall_prev;
    // No load-use operand holds: the dependent is held in ID and its operands
    // are captured into the id_ex pipe only at the release edge, so they are
    // always fresh (the non-load operand comes from the register file, which
    // any WB producer has already written by then).
    o_hazard_unit_pcsrc_gate = csr_stall_active;
end

//---------------------------------Flush---------------------------------\\

always_comb 
begin : flush_proc
    // A load-use is resolved by the MEM->EX forward, never by a flush:
    // flushing the EX stage here destroys the in-flight load (it vanishes from
    // the pipeline and its result never reaches the register file), so the
    // dependent instruction reads the stale pre-load value.
    //
    // flush_id fires immediately on a redirect so the wrong-path instruction in
    // ID is killed before the stall releases. flush_ex must be DEFERRED while
    // the pipeline is stalled (cache fill / mul busy): it clears the id_ex
    // pipe, which holds the resolving branch/jump itself. If it fires while the
    // stall is freezing the EX->MEM capture, the branch's writeback (e.g. a
    // jal's return address) is destroyed before it can reach WB. Deferring the
    // EX flush to the stall-release edge lets the branch advance EX->MEM (the
    // stall holds its id_ex copy until then) and clears the stale id_ex
    // contents on the same edge.
    //
    // The same deferral applies to the CSR flush source (faults, mret/sret,
    // interrupt setup): it clears the same id_ex pipe, and its conditions are
    // level-based on the stalled pipeline stage, so the flush stays asserted
    // through the stall and can be taken on the release edge. This protects a
    // writeback-producing instruction (e.g. a jal) sitting in EX when a CSR
    // flush fires during a cache fill.
    // A branch/jump in EX cannot resolve during the CSR-dependency stall pulse
    // (its stalled operand is stale), so its pcsrc_ex must not kill the ID
    // instruction either; the branch re-evaluates on the release cycle and
    // flushes then. The load-use stall never holds a stale branch in EX (it
    // bubbles EX), so pcsrc_ex during it is always legitimate and may kill the
    // held dependent immediately. The CSR flush sources are unaffected.
    //
    // Load-use bubble: while a read-data producer sits in EX with an ID-stage
    // dependent, flush the id_ex pipe to a bubble so the producer cannot be
    // re-executed in EX while it later sits in MEM (without the flush it
    // re-enters MEM on the LOAD_DONE release edge and double-services the
    // dcache/AMO). Deferred during cache/M stalls exactly like the branch
    // flush, so the producer still advances EX->MEM on the release edge.
    o_hazard_unit_flush_ex  = (load_stall_detection && load_in_ex && !mstall_detection && !icache_stall_detection && !dcache_stall_detection && !csr_stall_active) ||
                              ((i_hazard_unit_pcsrc_ex || i_hazard_unit_csr_flush_ex) && !mstall_detection && !icache_stall_detection && !dcache_stall_detection && !csr_stall_active && !load_stall_detection);
    o_hazard_unit_flush_id  = (i_hazard_unit_pcsrc_ex && !csr_stall_active) || i_hazard_unit_csr_flush_id;
    o_hazard_unit_flush_mem = i_hazard_unit_csr_flush_mem;
    o_hazard_unit_flush_wb  = i_hazard_unit_csr_flush_wb;
end

endmodule