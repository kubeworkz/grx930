module riscv_core_hazard_unit
(

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

    //CSR inputs
    input  logic i_hazard_unit_csr_flush_id,
    input  logic i_hazard_unit_csr_flush_ex,
    input  logic i_hazard_unit_csr_flush_mem,
    input  logic i_hazard_unit_csr_flush_wb
);

// Internals
logic mstall_detection;
logic icache_stall_detection;
logic dcache_stall_detection;

//------------------------------Forwarding------------------------------\\

always_comb 
begin : forwarding_proc

    // Forwarding SrcA
    if ((i_hazard_unit_rs1_ex == i_hazard_unit_rd_mem) && i_hazard_unit_regwrite_mem && (i_hazard_unit_rs1_ex != 5'b0)) 
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
    if ((i_hazard_unit_rs2_ex == i_hazard_unit_rd_mem) && i_hazard_unit_regwrite_mem && (i_hazard_unit_rs2_ex != 5'b0)) 
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
    // Load-use is resolved by the MEM->EX forward (the dcache read is
    // combinational, so the loaded value is valid while the load sits in MEM).
    // Stalling on it would hold the dependent in ID while stall_ex lets it also
    // advance to EX, so it is captured twice and re-executes. A load that
    // misses is already handled by dcache_stall, which freezes every stage
    // until the line is filled.
    o_hazard_unit_stall_if  = mstall_detection || icache_stall_detection || dcache_stall_detection;
    o_hazard_unit_stall_id  = mstall_detection || icache_stall_detection || dcache_stall_detection;
    // The ID/EX and EX/MEM pipes must also hold while the instruction cache is
    // filling: if only IF/ID is stalled, the instruction stuck in ID is
    // re-captured into EX every cycle and re-executed on each line fill.
    o_hazard_unit_stall_ex  = mstall_detection || icache_stall_detection || dcache_stall_detection;
    o_hazard_unit_stall_mem = mstall_detection || icache_stall_detection || dcache_stall_detection;
    // Freeze the MEM/WB pipe while either cache (or an MMIO access via the
    // dcache) is stalled: if a producer (e.g. li/lui feeding a store's data)
    // leaves WB while its consumer is held in EX, the WB->EX forward drops and
    // the consumer captures the stale pre-write register value into the
    // store-data pipe. Holding WB keeps the forward source live until the stall
    // releases, so the consumer latches the forwarded value.
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
    o_hazard_unit_flush_ex  = (((i_hazard_unit_pcsrc_ex || i_hazard_unit_csr_flush_ex) && !mstall_detection && !icache_stall_detection && !dcache_stall_detection));
    o_hazard_unit_flush_id  = i_hazard_unit_pcsrc_ex || i_hazard_unit_csr_flush_id;
    o_hazard_unit_flush_mem = i_hazard_unit_csr_flush_mem;
    o_hazard_unit_flush_wb  = i_hazard_unit_csr_flush_wb;
end

endmodule