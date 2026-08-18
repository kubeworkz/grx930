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
    if ((i_hazard_unit_rs1_ex == i_hazard_unit_rd_mem) && i_hazard_unit_regwrite_mem && (i_hazard_unit_rs1_ex != 5'b0) && (i_hazard_unit_resultsrc_mem != 2'b11))
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
    if ((i_hazard_unit_rs2_ex == i_hazard_unit_rd_mem) && i_hazard_unit_regwrite_mem && (i_hazard_unit_rs2_ex != 5'b0) && (i_hazard_unit_resultsrc_mem != 2'b11))
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
    // Load-use is resolved by the MEM->EX forward (the dcache read is
    // combinational, so the loaded value is valid while the load sits in MEM).
    // Stalling on it would hold the dependent in ID while stall_ex lets it also
    // advance to EX, so it is captured twice and re-executes. A load that
    // misses is already handled by dcache_stall, which freezes every stage
    // until the line is filled.
    o_hazard_unit_stall_if  = mstall_detection || icache_stall_detection || dcache_stall_detection || csr_stall_active;
    o_hazard_unit_stall_id  = mstall_detection || icache_stall_detection || dcache_stall_detection || csr_stall_active;
    // The ID/EX and EX/MEM pipes must also hold while the instruction cache is
    // filling: if only IF/ID is stalled, the instruction stuck in ID is
    // re-captured into EX every cycle and re-executed on each line fill.
    o_hazard_unit_stall_ex  = mstall_detection || icache_stall_detection || dcache_stall_detection || csr_stall_active;
    o_hazard_unit_stall_mem = mstall_detection || icache_stall_detection || dcache_stall_detection || csr_stall_active;
    // Freeze the MEM/WB pipe while either cache (or an MMIO access via the
    // dcache) is stalled: if a producer (e.g. li/lui feeding a store's data)
    // leaves WB while its consumer is held in EX, the WB->EX forward drops and
    // the consumer captures the stale pre-write register value into the
    // store-data pipe. Holding WB keeps the forward source live until the stall
    // releases, so the consumer latches the forwarded value. A CSR-dependency
    // stall deliberately excludes stall_wb: the CSR producer must advance
    // MEM->WB for its value to become available.
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
    o_hazard_unit_flush_ex  = (((i_hazard_unit_pcsrc_ex || i_hazard_unit_csr_flush_ex) && !mstall_detection && !icache_stall_detection && !dcache_stall_detection && !csr_stall_active));
    o_hazard_unit_flush_id  = i_hazard_unit_pcsrc_ex || i_hazard_unit_csr_flush_id;
    o_hazard_unit_flush_mem = i_hazard_unit_csr_flush_mem;
    o_hazard_unit_flush_wb  = i_hazard_unit_csr_flush_wb;
end

endmodule