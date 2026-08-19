module riscv_core_hazard_unit
(

    // Clock / reset (CSR-read stall ex_mem drain pulse: freezes the EX->MEM
    // pipe for exactly one cycle while the CSR producer's id_ex copy has been
    // bubbled, so the bubble-EX output cannot clobber the producer in MEM).
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
    output logic o_hazard_unit_flush_wb,    //CSR inputs
    input  logic i_hazard_unit_csr_flush_id,
    input  logic i_hazard_unit_csr_flush_ex,
    input  logic i_hazard_unit_csr_flush_mem,
    input  logic i_hazard_unit_csr_flush_wb,
    // Result sources by stage. resultsrc==2'b11 (CSR read data) only exists at
    // WB: its MEM-stage ALU result is unrelated garbage, and the WB read-data
    // mux output (csr_rdata_wb) is COMBINATIONAL in WB (the one-hot select is
    // registered, the data merge is not). A dependent on a CSR read is therefore
    // held in ID by the CSR-read stall (below) until the producer's regfile
    // write commits at the WB negedge, and the WB->EX forward never carries CSR
    // read data -- so the combinational CSR mux leaves the EX critical path.
    input  logic [1:0] i_hazard_unit_resultsrc_mem,
    input  logic [1:0] i_hazard_unit_resultsrc_wb
);

// Internals
logic mstall_detection;
logic icache_stall_detection;
logic dcache_stall_detection;
logic csr_stall_detection;
logic csr_dep_rs1;
logic csr_dep_rs2;
logic load_stall_detection;
logic load_dep_rs1;
logic load_dep_rs2;
logic load_in_ex;
logic load_in_mem;
logic csr_in_ex;
logic csr_mem_hold;

// One-shot EX->MEM drain for the CSR-read stall. While a CSR-read producer
// (resultsrc == 2'b11) sits in EX with an ID-stage dependent, flush_ex bubbles
// the id_ex pipe so the producer is never re-executed (the load-use stall does
// the same). The producer then spends one cycle in MEM with a bubble in EX;
// without a freeze the bubble-EX output would clobber the producer's ex_mem
// copy on the next edge and its writeback would be lost. dcache_stall provides
// that freeze for loads; a CSR read has no dcache service, so this flop pulses
// stall_mem for exactly the cycle the producer is first in MEM (gated on the
// pipeline actually moving, so a cache/M stall that holds the producer in EX
// simply keeps the pulse armed instead of deadlocking on the pipe contents).
always_ff @(posedge i_hazard_unit_clk or negedge i_hazard_unit_rst_n)
begin
    if (!i_hazard_unit_rst_n)
        csr_mem_hold <= 1'b0;
    else
        csr_mem_hold <= csr_stall_detection && csr_in_ex &&
                        !mstall_detection && !icache_stall_detection && !dcache_stall_detection;
end


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
    // The WB->EX forward source (wb_fwd_data in the top) carries only the
    // REGISTERED mem_wb pipes -- never the combinational CSR read data. A
    // dependent on a CSR read is held in ID by the CSR-read stall until the
    // producer's regfile write commits, so it never needs (and never gets) a
    // WB->EX forward for resultsrc==2'b11.
    else if ((i_hazard_unit_rs1_ex == i_hazard_unit_rd_wb) && i_hazard_unit_regwrite_wb && (i_hazard_unit_rs1_ex != 5'b0) && (i_hazard_unit_resultsrc_wb != 2'b11)) 
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
    else if ((i_hazard_unit_rs2_ex == i_hazard_unit_rd_wb) && i_hazard_unit_regwrite_wb && (i_hazard_unit_rs2_ex != 5'b0) && (i_hazard_unit_resultsrc_wb != 2'b11)) 
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
    // CSR-read hazard (ID-based, mirrors the load-use stall). A CSR read
    // (resultsrc == 2'b11) produces its value only in WB, and the WB read-data
    // mux output is COMBINATIONAL (registered one-hot select x registered CSR
    // values) -- it cannot be forwarded to EX without putting the CSR decode
    // on the critical path. Instead, a dependent in ID whose source matches a
    // CSR-read producer in EX, MEM, or WB is held in ID (level-based) until
    // the producer's regfile write commits at the WB negedge; the dependent
    // then captures the committed value at the WB posedge. The producer is
    // NEVER frozen (stall_ex/mem/wb stay clear for this stall), so it flows
    // EX->MEM->WB exactly as unstalled and its write lands on schedule -- no
    // pulse, no operand holds, no re-fire logic; a cache fill merely extends
    // the level while the producer waits, and the dependent releases when the
    // write finally lands.
    csr_dep_rs1 = (i_hazard_unit_rs1_id != 5'b0) &&
                  (((i_hazard_unit_resultsrc_ex  == 2'b11) && i_hazard_unit_regwrite_ex  && (i_hazard_unit_rs1_id == i_hazard_unit_rd_ex))  ||
                   ((i_hazard_unit_resultsrc_mem  == 2'b11) && i_hazard_unit_regwrite_mem  && (i_hazard_unit_rs1_id == i_hazard_unit_rd_mem)) ||
                   ((i_hazard_unit_resultsrc_wb   == 2'b11) && i_hazard_unit_regwrite_wb   && (i_hazard_unit_rs1_id == i_hazard_unit_rd_wb)));
    csr_dep_rs2 = (i_hazard_unit_rs2_id != 5'b0) &&
                  (((i_hazard_unit_resultsrc_ex  == 2'b11) && i_hazard_unit_regwrite_ex  && (i_hazard_unit_rs2_id == i_hazard_unit_rd_ex))  ||
                   ((i_hazard_unit_resultsrc_mem  == 2'b11) && i_hazard_unit_regwrite_mem  && (i_hazard_unit_rs2_id == i_hazard_unit_rd_mem)) ||
                   ((i_hazard_unit_resultsrc_wb   == 2'b11) && i_hazard_unit_regwrite_wb   && (i_hazard_unit_rs2_id == i_hazard_unit_rd_wb)));
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
    csr_in_ex   = (i_hazard_unit_resultsrc_ex == 2'b11) && i_hazard_unit_regwrite_ex;
    load_dep_rs1 = (((load_in_ex) && (i_hazard_unit_rs1_id == i_hazard_unit_rd_ex)) ||
                    ((load_in_mem) && i_hazard_unit_dcache_stall && (i_hazard_unit_rs1_id == i_hazard_unit_rd_mem))) &&
                   (i_hazard_unit_rs1_id != 5'b0);
    load_dep_rs2 = (((load_in_ex) && (i_hazard_unit_rs2_id == i_hazard_unit_rd_ex)) ||
                    ((load_in_mem) && i_hazard_unit_dcache_stall && (i_hazard_unit_rs2_id == i_hazard_unit_rd_mem))) &&
                   (i_hazard_unit_rs2_id != 5'b0);
    load_stall_detection = load_dep_rs1 || load_dep_rs2;
    o_hazard_unit_stall_if  = mstall_detection || icache_stall_detection || dcache_stall_detection || csr_stall_detection || load_stall_detection;
    o_hazard_unit_stall_id  = mstall_detection || icache_stall_detection || dcache_stall_detection || csr_stall_detection || load_stall_detection;
    // The ID/EX pipe must also hold while the instruction cache is filling or
    // a load-use is pending: if only IF/ID is stalled, the instruction stuck
    // in ID would be re-captured into EX every cycle. (The load-use stall also
    // flushes the id_ex pipe to a bubble while the producer sits in EX - see
    // flush_proc - so the producer is never re-executed in EX while it flows
    // EX->MEM->WB.) stall_mem/wb stay clear for the load-use stall so the
    // producer advances and its registered data window is undisturbed.
    //
    // The CSR-read stall must ALSO freeze the ID->EX pipe (stall_ex) while the
    // dependent waits in ID: with stall_ex clear, the id_ex pipe would capture
    // the dependent from ID on the producer's MEM cycle, and with no WB->EX
    // forward for CSR data (the retiming) it would execute with a stale
    // operand. Freezing id_ex (stall_ex) plus the flush_ex bubble below keeps
    // it a bubble; the producer flows EX->MEM->WB because stall_mem/wb stay
    // clear (except for the one-cycle csr_mem_hold drain, which protects the
    // producer's ex_mem copy from the bubble-EX output). The dependent then
    // captures the committed regfile value at the release edge.
    o_hazard_unit_stall_ex  = mstall_detection || icache_stall_detection || dcache_stall_detection || csr_stall_detection || load_stall_detection;
    o_hazard_unit_stall_mem = mstall_detection || icache_stall_detection || dcache_stall_detection || csr_mem_hold;
    // Freeze the MEM/WB pipe while either cache (or an MMIO access via the
    // dcache) is stalled: if a producer (e.g. li/lui feeding a store's data)
    // leaves WB while its consumer is held in EX, the WB->EX forward drops and
    // the consumer captures the stale pre-write register value into the
    // store-data pipe. Holding WB keeps the forward source live until the stall
    // releases, so the consumer latches the forwarded value. The CSR- and
    // load-use-dependency stalls deliberately exclude stall_wb: the producer
    // must advance MEM->WB for its value to become available.
    o_hazard_unit_stall_wb  = mstall_detection || icache_stall_detection || dcache_stall_detection;
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
    // A branch/jump in EX resolves with valid operands during the CSR-read
    // stall (it is not a dependent -- a CSR-dependent branch would itself be
    // held in ID), so its pcsrc_ex may kill the held ID instruction (which is
    // wrong-path) and redirect the fetch immediately. The CSR flush sources
    // are unaffected. The load-use stall never holds a stale branch in EX (it
    // bubbles EX), so pcsrc_ex during it is always legitimate and may kill the
    // held dependent immediately.
    //
    // Load-use bubble: while a read-data producer sits in EX with an ID-stage
    // dependent, flush the id_ex pipe to a bubble so the producer cannot be
    // re-executed in EX while it later sits in MEM (without the flush it
    // re-enters MEM on the LOAD_DONE release edge and double-services the
    // dcache/AMO). Deferred during cache/M stalls exactly like the branch
    // flush, so the producer still advances EX->MEM on the release edge.
    //
    // CSR-read bubble: same mechanism for a CSR-read producer in EX -- clear
    // the id_ex copy so it cannot re-execute while it sits in MEM (a ghost
    // would keep resultsrc_ex == 2'b11 asserted and deadlock the stall). The
    // csr_mem_hold pulse then protects the producer's ex_mem copy for its one
    // MEM cycle.
    o_hazard_unit_flush_ex  = (load_stall_detection && load_in_ex && !mstall_detection && !icache_stall_detection && !dcache_stall_detection && !csr_stall_detection) ||
                              (csr_stall_detection && csr_in_ex && !mstall_detection && !icache_stall_detection && !dcache_stall_detection && !load_stall_detection) ||
                              ((i_hazard_unit_pcsrc_ex || i_hazard_unit_csr_flush_ex) && !mstall_detection && !icache_stall_detection && !dcache_stall_detection && !csr_stall_detection && !load_stall_detection);
    o_hazard_unit_flush_id  = i_hazard_unit_pcsrc_ex || i_hazard_unit_csr_flush_id;
    o_hazard_unit_flush_mem = i_hazard_unit_csr_flush_mem;
    o_hazard_unit_flush_wb  = i_hazard_unit_csr_flush_wb;
end

endmodule