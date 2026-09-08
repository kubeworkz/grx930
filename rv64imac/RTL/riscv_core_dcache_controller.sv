`define TAG 63:12
`define INDEX 11:5
`define BLOCK_OFFSET 4:3
`define BYTE_OFFSET 2:0
`define OFFSET 5


module riscv_core_dcache_controller #(
    parameter BLOCK_OFFSET      = 2,
    parameter INDEX_WIDTH       = 7,
    parameter TAG_WIDTH         = 52,
    parameter CORE_DATA_WIDTH   = 64,
    parameter ADDR_WIDTH        = 64,
    parameter AXI_DATA_WIDTH    = 256,
    parameter [63:0] MMIO_BASE  = 64'h4000_0000
) (


    // Interface with CORE//
  
    input logic                         i_clk,
    input logic                         i_rst_n,
    input logic [CORE_DATA_WIDTH-1 : 0] i_data_from_core ,
    input logic [ADDR_WIDTH-1      : 0] i_addr_from_core ,
    input logic                         i_read,
    input logic                         i_write,
    input logic                 [1:0]   i_size,
    input logic                         i_amo,
    input logic                         i_lr,
    input logic                         i_sc,
    input logic [CORE_DATA_WIDTH-1 : 0] i_amo_alu_result ,
    output logic                        o_stall,
    output logic                        o_amo_result_pending,
    output logic                        o_store_fault,
    output logic                        o_load_fault,
    output logic                        o_amo_fault,
    output logic [ CORE_DATA_WIDTH-1  :  0  ]  o_sc_result,


    // Interface with CACHE MEM //

    output logic                         o_rd_en,
    output logic                         o_wr_en,
    output logic                         o_block_replace,
    output logic                         o_amo_wr,

    // Interface with AXI READ CHANNEL //

    output logic [ADDR_WIDTH-1     : 0] o_mem_read_address,
    output logic                        o_mem_read_req,
    input  logic                        i_mem_read_done,

    // Interface with AXI WRITE CHANNEL //

    input logic                           i_mem_write_done,
    output logic                          o_mem_write_valid,
    output logic [CORE_DATA_WIDTH-1 : 0]  o_mem_write_data,
    output logic [     ADDR_WIDTH-1 : 0]  o_mem_write_address,
    output logic [                7 : 0]  o_mem_write_strobe,

    // MMIO (uncached peripheral) port
    output logic [ADDR_WIDTH-1     : 0]  o_mmio_read_address,
    output logic                        o_mmio_read_req,
    output logic                        o_mmio_read_sel,
    input  logic                        i_mmio_read_done,
    output logic [ADDR_WIDTH-1     : 0]  o_mmio_write_address,
    output logic [CORE_DATA_WIDTH-1 : 0] o_mmio_write_data,
    output logic [                7 : 0] o_mmio_write_strobe,
    output logic                        o_mmio_write_valid,
    input  logic                        i_mmio_write_done,

    // Coherence invalidation (from the shared L2).  i_inv_valid stays high
    // until o_inv_ack.  The ack means ACCEPTED: the line will be cleared in
    // IDLE before any subsequent core request is serviced (clear-before-use),
    // so the L2 never deadlocks waiting for a busy cache.
    input  logic                        i_inv_valid,
    input  logic [ADDR_WIDTH-1     : 0] i_inv_addr,
    output logic                        o_inv_ack
);

///////////////////////////////////////////////
//             LOCAL PARAMETERS              //
///////////////////////////////////////////////

localparam CACHE_DEPTH = 2**INDEX_WIDTH ;


///////////////////////////////////////////////
//      INTERNAL REGISTERS AND MEMORIES      //
///////////////////////////////////////////////


logic [  TAG_WIDTH-1 : 0  ] TAG_MEM  [0: CACHE_DEPTH-1];
logic                      VALID_MEM [0: CACHE_DEPTH-1];

logic                      VALID_RES , NEXT_VALID_RES;
logic [  ADDR_WIDTH-1: 0  ] RES_SET , NEXT_RES_SET ; 
logic [            1 : 0  ] RES_SET_SIZE , NEXT_RES_SET_SIZE ;

logic                       res_set_hit;


enum logic [3:0] {
    IDLE           = 4'b0000,
    MEM_REQ        = 4'b0001,
    UPDATE_CACHE   = 4'b0010,
    MEM_WRITE      = 4'b0011,
    AMO_OP         = 4'b0100,
    MMIO_READ      = 4'b0101,
    MMIO_WRITE     = 4'b0110,
    MMIO_DRAIN     = 4'b0111,
    // One-cycle pass-through after a cache-read hit (load/LR). The memory
    // read is REGISTERED (EBR-mappable), so the data is valid one cycle after
    // o_rd_en; the core samples it here with o_stall released. The request
    // lines stay asserted (the load is still in MEM until the posedge), so
    // this state must NOT re-dispatch -- it just drains to IDLE.
    LOAD_DONE      = 4'b1000,
    // After an MMIO store completes (done seen), the store must retire from
    // MEM before the dcache returns to IDLE.  If the pipe cannot advance on
    // the done cycle (e.g. the I-cache is mid-fill and holds the WB stage via
    // the hazard unit's stall_wb), the store stays in MEM with i_write high;
    // returning to IDLE then RE-ISSUES the completed store as a brand-new
    // MMIO write.  That is harmless for idempotent config writes but fatal
    // for non-idempotent ones (the NPU CSR START bit -> duplicate GEMM).
    // MMIO_WR_RETIRE releases the pipe (o_stall=0, valid deasserted) and
    // waits for the store to actually leave MEM before draining.
    MMIO_WR_RETIRE = 4'b1001
} STATE , NEXT ;   // STATE/NEXT initialized to IDLE in the initial block below

  // Address of the MMIO store currently being retired (latched when its write
  // completes), so MMIO_WR_RETIRE can tell whether the MEM stage still holds
  // the same store or has advanced to a new access.
  logic [ADDR_WIDTH-1 : 0] mmio_wr_addr_r;
// Initializers keep the combinational FSM/tag/reservation logic defined before
// the first reset edge (Icarus would otherwise cascade X through the cache).
initial begin
    for ( int i = 0 ; i < CACHE_DEPTH  ; i=i+1 ) begin
        TAG_MEM[i] = 'b0;
        VALID_MEM[i] = 1'b0;
    end
    VALID_RES = 1'b0;
    RES_SET = 'b0;
    RES_SET_SIZE = 2'b0;
    STATE = IDLE;
    NEXT = IDLE;
end

logic                      update_en;
// One pending coherence invalidation slot (accepted in any state, applied in
// IDLE before the next core request).
logic                      pending_inv = 1'b0;
logic [ADDR_WIDTH-1:0]     pending_inv_addr = 'b0;

assign o_inv_ack = i_inv_valid && !pending_inv;
logic                      tag_hit;
logic                      fault;

// Remembers that the AMO/SC currently sitting in the core's MEM stage has
// already been fully serviced (its write-through landed and the cache line was
// updated). An independent stall (e.g. an instruction-cache fill after a taken
// branch) freezes the pipeline, so the instruction cannot advance MEM->WB and
// the LEVEL-based i_amo/i_sc stay asserted. IDLE would otherwise re-dispatch
// and re-execute the same AMO (applying the op twice) or SC. Skip re-dispatch
// until the request deasserts, i.e. until the core actually advanced.
logic                      amo_sc_serviced;

// The AMO result the core must capture is the OLD memory value, which the
// memory array no longer holds once the AMO write-through lands. If the WB
// capture is delayed past the transaction (frozen pipeline), present the
// latched old value on the read port until the request deasserts.
assign o_amo_result_pending = amo_sc_serviced && i_amo;

/////////////////////////////////////////////////
//    ASSIGNING NEXT STATE AND UPDATE BLOCK    //
/////////////////////////////////////////////////

always_ff @( posedge i_clk , negedge i_rst_n ) begin : NEXT_STATE_ASSIGN_FLUSH_UPDATE_BLOCK
    if (!i_rst_n) begin
        // Clear ALL Valid Entries //


        for ( int i = 0 ; i < CACHE_DEPTH  ; i=i+1 ) begin
            VALID_MEM[i] <= 0;
        end
        VALID_RES <= 0;
        RES_SET <= 0;
        RES_SET_SIZE <= 0;
        amo_sc_serviced <= 0;
        mmio_wr_addr_r <= 0;
        pending_inv <= 1'b0;
        STATE <= IDLE;
    end

    else 
    begin
        // Accept a coherence invalidation (one pending slot).
        if (i_inv_valid && !pending_inv) begin
            pending_inv      <= 1'b1;
            pending_inv_addr <= i_inv_addr;
        end

        // Latch the address of a completing MMIO store (same edge that
        // transitions to MMIO_WR_RETIRE) so the retire state can detect
        // when the store leaves the MEM stage.
        if ((STATE == MMIO_WRITE) && i_mmio_write_done)
            mmio_wr_addr_r <= i_addr_from_core;
        STATE <= NEXT ;
        VALID_RES <= NEXT_VALID_RES;
        RES_SET <= NEXT_RES_SET;
        RES_SET_SIZE <= NEXT_RES_SET_SIZE;

        // Set once the AMO/SC write-through completes; clear when the request
        // deasserts (the core advanced the instruction out of MEM).
        if ((STATE == MEM_WRITE) && i_mem_write_done && (i_amo || i_sc))
            amo_sc_serviced <= 1'b1;
        else if (!(i_amo || i_sc))
            amo_sc_serviced <= 1'b0;

        // UPDATE VALID MEM in case of BLOCK REPLACEMENT //
        // (TAG_MEM is written in its own no-reset block below -- an async-
        // reset-sensitive block demotes every memory written from it to
        // registers in synthesis, killing DPR16X4 inference.)
        if (update_en) begin
           VALID_MEM     [  i_addr_from_core[`INDEX]   ] <= 1'b1; 
        end
        // Apply a pending coherence invalidation in IDLE, tag-checked, before
        // the next core request is serviced.  Placed after the update_en
        // write so a same-cycle valid-set loses to the invalidation.
        if (STATE == IDLE && pending_inv) begin
            pending_inv <= 1'b0;
            if (TAG_MEM[pending_inv_addr[`INDEX]] == pending_inv_addr[`TAG])
                VALID_MEM[pending_inv_addr[`INDEX]] <= 1'b0;
        end
    end
end

// TAG storage: written only on a line fill, read combinationally by the tag
// compare. Kept in a separate always_ff with NO reset -- distributed-RAM
// storage has no reset, and a line is only trusted when VALID_MEM says so,
// so stale tags are never observable. This is what lets yosys map TAG_MEM
// to DPR16X4 instead of ~6.6K FFs.
always_ff @( posedge i_clk ) begin : TAG_UPDATE_BLOCK
    if (update_en) begin
        TAG_MEM [ i_addr_from_core[`INDEX] ] <= i_addr_from_core[`TAG];
    end
end

/////////////////////////////////////////////////
//            TAG COMPARISON BLOCK             //
/////////////////////////////////////////////////

// Icarus Verilog does not re-trigger sensitivity on array element NBA updates
// when the read is inside an 'assign' statement. Using always_comb ensures the
// block re-evaluates when VALID_MEM or TAG_MEM elements change.
always_comb begin : TAG_HIT_BLOCK
    tag_hit = (TAG_MEM[i_addr_from_core[`INDEX]] == i_addr_from_core[`TAG]) && VALID_MEM[i_addr_from_core[`INDEX]];
end 

// MMIO (uncached peripheral) region detection
logic                      mmio_sel;
assign   mmio_sel   = (i_addr_from_core >= MMIO_BASE);




/////////////////////////////////////////////////
//            FSM TRANSITION BLOCK             //
/////////////////////////////////////////////////

always_comb begin : FSM_TRANSITION_BLOCK


// DEFAULT VALUES //

o_rd_en = 0;
o_wr_en = 0;
o_block_replace = 0;
o_stall = 0;
o_mem_read_address = {i_addr_from_core[`TAG] , i_addr_from_core[`INDEX],`OFFSET'b0};
o_mem_read_req = 0;
update_en = 0;
o_amo_wr = 0;
o_sc_result = 0;

o_mem_write_data = i_data_from_core;
o_mem_write_address = i_addr_from_core;
o_mem_write_valid = 0;

o_mmio_read_req      = 0;
o_mmio_read_sel      = 0;
o_mmio_read_address  = i_addr_from_core;
o_mmio_write_valid   = 0;
o_mmio_write_address = i_addr_from_core;
o_mmio_write_data    = i_data_from_core;
o_mmio_write_strobe  = o_mem_write_strobe;

NEXT = STATE ;
NEXT_RES_SET = RES_SET;
NEXT_VALID_RES = VALID_RES;
NEXT_RES_SET_SIZE = RES_SET_SIZE;


case (STATE)
    IDLE   : begin
        // DEFAULT VALUES FOR IDLE//
        // COHERENCE INVALIDATION: service the pending clear before any core
        // request (the clear itself is in the NEXT_STATE_ASSIGN block).
        if (pending_inv) begin
            o_stall = 1;
            NEXT = IDLE;
        end else begin

        o_rd_en = 0;
        o_wr_en = 0;
        o_block_replace = 0;
        o_stall = 0;
        o_mem_read_address = {i_addr_from_core[`TAG] , i_addr_from_core[`INDEX],`OFFSET'b0};
        o_mem_read_req = 0;
        update_en = 0;
        o_amo_wr = 0;

        o_mem_write_data = i_data_from_core;
        o_mem_write_address = i_addr_from_core;
        o_mem_write_valid = 0;
        

        // MMIO (uncached peripheral) access //

        if (mmio_sel) begin
            if (i_read) begin
                o_mmio_read_req = 1;
                o_stall = 1;
                NEXT = MMIO_READ;
            end
            else if (i_write) begin
                o_mmio_write_valid = 1;
                o_stall = 1;
                NEXT = MMIO_WRITE;
            end
        end

        // READ INSTRUCTIONS //

            if (!mmio_sel && i_read) begin
                if (tag_hit) begin // READ HIT (registered read: stall 1 cycle so the core samples the data in LOAD_DONE)
                    if (!fault)
                    begin
                    o_rd_en = 1;
                    o_stall = 1;
                    NEXT = LOAD_DONE;
                    end
                    else
                    o_rd_en = 0;
                end
                else if(!tag_hit && !fault) begin // READ MISS

                    o_stall = 1;
                    o_mem_read_req = 1;
                    o_mem_read_address = {i_addr_from_core[`TAG] , i_addr_from_core[`INDEX],`OFFSET'b0};
                    NEXT = MEM_REQ;
                end    
            end

        // LR INSTRUCTIONS //

           else if (!mmio_sel && i_lr) begin
                if (tag_hit) begin // READ HIT
                    if (!fault)

                    begin
                       o_rd_en = 1;
                       o_stall = 1;
                       NEXT = LOAD_DONE;
                       NEXT_RES_SET = i_addr_from_core;
                       NEXT_VALID_RES =1;  
                       NEXT_RES_SET_SIZE = i_size;
                    end
                   
                    else
                    o_rd_en = 0;
                end
                else if(!tag_hit && !fault) begin // READ MISS

                    o_stall = 1;
                    o_mem_read_req = 1;
                    o_mem_read_address = {i_addr_from_core[`TAG] , i_addr_from_core[`INDEX],`OFFSET'b0};
                    NEXT = MEM_REQ;
                end    
            end

        // WRITE INSTRUCTIONS //

            else if(!mmio_sel && i_write) begin
                if (tag_hit) begin
                       if (!fault) begin
                       o_wr_en = 1;
                       o_mem_write_valid = 1;
                       o_stall = 1;
                       NEXT = MEM_WRITE;
                       end
                       else 
                       begin
                       o_wr_en = 0;
                       end 
                    end  
                else if(!tag_hit && !fault) begin // WRITE MISS

                    o_stall = 1;
                    o_mem_read_req = 1;
                    o_mem_read_address = {i_addr_from_core[`TAG] , i_addr_from_core[`INDEX],`OFFSET'b0};
                    NEXT = MEM_REQ;
                end 
            end


            // SC INSTRUCTIONS //

            else if(!mmio_sel && i_sc && !amo_sc_serviced) begin
                if (tag_hit) begin // WRITE HIT
                NEXT_VALID_RES = 0;
                       if (!fault && res_set_hit) begin // SC HIT
                       o_wr_en = 1;
                       o_mem_write_valid = 1;
                       o_stall = 1;
                       NEXT = MEM_WRITE;
                       end
                       else 
                       begin
                       o_wr_en = 0;
                       o_sc_result = 1;
                       end 
                    end  
                else if(!tag_hit && !fault) begin // WRITE MISS

                    o_stall = 1;
                    o_mem_read_req = 1;
                    o_mem_read_address = {i_addr_from_core[`TAG] , i_addr_from_core[`INDEX],`OFFSET'b0};
                    NEXT = MEM_REQ;
                end 
            end

            // AMO INSTRUCTIONS //


            else if(!mmio_sel && i_amo && !amo_sc_serviced) begin
                if (tag_hit) begin // AMO_READ HIT
                    if (!fault)
                    begin
                    o_rd_en = 1;
                    o_stall = 1;
                    NEXT = AMO_OP;  
                    end
                    else
                    o_rd_en = 0;
                end
                else if(!tag_hit && !fault) begin // AMO_READ MISS

                    o_stall = 1;
                    o_mem_read_req = 1;
                    o_mem_read_address = {i_addr_from_core[`TAG] , i_addr_from_core[`INDEX],`OFFSET'b0};
                    NEXT = MEM_REQ;
                end
            end
        end
    end
     LOAD_DONE : begin

        // The registered read from the previous cycle is valid now; release
        // the stall so the load advances MEM->WB and samples o_data_to_core.
        // All other outputs keep their defaults (no new request is taken --
        // the load is still in MEM until the posedge, so re-dispatching here
        // would double-service it).
        o_rd_en = 0;
        o_wr_en = 0;
        o_block_replace = 0;
        o_stall = 0;
        o_mem_read_address = {i_addr_from_core[`TAG] , i_addr_from_core[`INDEX],`OFFSET'b0};
        o_mem_read_req = 0;
        update_en = 0;
        o_amo_wr = 0;

        o_mem_write_data = i_data_from_core;
        o_mem_write_address = i_addr_from_core;
        o_mem_write_valid = 0;

        NEXT = IDLE;
               end


     MEM_REQ : begin

        o_rd_en = 0;
        o_wr_en = 0;
        o_block_replace = 0;
        o_stall = 1;
        o_mem_read_address = {i_addr_from_core[`TAG] , i_addr_from_core[`INDEX],`OFFSET'b0};
        o_mem_read_req = 1;
        update_en = 0;
        o_amo_wr = 0;

        o_mem_write_data = i_data_from_core;
        o_mem_write_address = i_addr_from_core;
        o_mem_write_valid = 0;

        if (i_mem_read_done) begin
            o_mem_read_req = 0;
            NEXT = UPDATE_CACHE;
        end
               end


      UPDATE_CACHE : begin

        o_rd_en = 0;
        o_wr_en = 1;
        o_block_replace = 1;
        o_stall = 1;
        o_mem_read_address = {i_addr_from_core[`TAG] , i_addr_from_core[`INDEX],`OFFSET'b0};
        o_mem_read_req = 0;
        update_en = 1;
        o_amo_wr = 0;

        o_mem_write_data = i_amo_alu_result;
        o_mem_write_address = i_addr_from_core;
        o_mem_write_valid = 0;
        
        NEXT = IDLE;
                    end 


      MEM_WRITE : begin

        o_rd_en = 0;
        o_wr_en = 0;
        o_block_replace = 0;
        o_stall = 1;
        o_mem_read_address = {i_addr_from_core[`TAG] , i_addr_from_core[`INDEX],`OFFSET'b0};
        o_mem_read_req = 0;
        update_en = 0;
        o_amo_wr = 0;
        
        o_mem_write_address = i_addr_from_core;
        o_mem_write_valid = 1;


// Check if it is a write from AMO or ordinary Store instruction

        if (i_amo)
        begin
            o_mem_write_data = i_amo_alu_result;
            o_rd_en = 1;
        end
        else
        begin
            o_mem_write_data = i_data_from_core;
        end

        if (i_mem_write_done) begin
            o_mem_write_valid = 0;
            o_stall =0 ;
            NEXT = IDLE;

            if (i_amo) begin
                o_wr_en = 1; 
                o_amo_wr = 1; 
            end
            else begin
                // Write the store/SC data into the cache line as well: a store
                // MISS fills the line with the stale block, so without this the
                // cache holds the pre-store value and a later read/AMO on the
                // same line sees stale data (write-through only hits DDR).
                o_wr_en = 1;
            end
        end
               end 

      AMO_OP : begin

        o_rd_en = 1;
        o_wr_en = 0;
        o_block_replace = 0;
        o_stall = 1;
        o_mem_read_address = {i_addr_from_core[`TAG] , i_addr_from_core[`INDEX],`OFFSET'b0};
        o_mem_read_req = 0;
        update_en = 0;
        o_amo_wr = 0;
        
        o_mem_write_data = i_data_from_core;
        o_mem_write_address = i_addr_from_core;
        o_mem_write_valid = 0;

        NEXT = MEM_WRITE;

               end 
      MMIO_READ : begin

        o_rd_en = 0;
        o_wr_en = 0;
        o_block_replace = 0;
        o_stall = 1;
        o_mem_read_address = {i_addr_from_core[`TAG] , i_addr_from_core[`INDEX],`OFFSET'b0};
        o_mem_read_req = 0;
        update_en = 0;
        o_amo_wr = 0;

        o_mem_write_data = i_data_from_core;
        o_mem_write_address = i_addr_from_core;
        o_mem_write_valid = 0;

        o_mmio_read_req = 1;
        o_mmio_read_sel = 1;

        if (i_mmio_read_done) begin
            o_mmio_read_req = 0;
            o_stall = 0;
            NEXT = MMIO_DRAIN;
        end

               end 

      MMIO_WRITE : begin

        o_rd_en = 0;
        o_wr_en = 0;
        o_block_replace = 0;
        o_stall = 1;
        o_mem_read_address = {i_addr_from_core[`TAG] , i_addr_from_core[`INDEX],`OFFSET'b0};
        o_mem_read_req = 0;
        update_en = 0;
        o_amo_wr = 0;

        o_mem_write_data = i_data_from_core;
        o_mem_write_address = i_addr_from_core;
        o_mem_write_valid = 0;

        o_mmio_write_valid = 1;

        if (i_mmio_write_done) begin
            o_mmio_write_valid = 0;
            o_stall = 0;
            // The completed store's address is latched into mmio_wr_addr_r by
            // the always_ff below (STATE==MMIO_WRITE && done), so
            // MMIO_WR_RETIRE can detect when the store leaves MEM.
            NEXT = MMIO_WR_RETIRE;
        end

               end 

      // Let the completed MMIO store retire from the pipeline.  The write
      // itself is DONE (the bridge consumed it); we only need the store to
      // advance MEM->WB so the dcache does not re-issue it.  With o_stall
      // released the pipe advances the moment the WB stage is free (when any
      // concurrent I-cache fill that held stall_wb completes).  We hold the
      // request deasserted the whole time and wait until the MEM stage no
      // longer holds THIS store (i_write drops or the address changes), then
      // drain so IDLE services the next access.  Without this state, IDLE
      // re-issues the completed store -> duplicate MMIO write (fatal for
      // non-idempotent targets like the NPU CSR START bit).
      MMIO_WR_RETIRE : begin

        o_rd_en = 0;
        o_wr_en = 0;
        o_block_replace = 0;
        o_stall = 0;                     // release the pipe so the store retires
        o_mem_read_address = {i_addr_from_core[`TAG] , i_addr_from_core[`INDEX],`OFFSET'b0};
        o_mem_read_req = 0;
        update_en = 0;
        o_amo_wr = 0;

        o_mem_write_data = i_data_from_core;
        o_mem_write_address = i_addr_from_core;
        o_mem_write_valid = 0;

        o_mmio_read_req      = 0;
        o_mmio_read_sel      = 0;
        o_mmio_read_address  = i_addr_from_core;
        o_mmio_write_valid   = 0;
        o_mmio_write_address = i_addr_from_core;
        o_mmio_write_data    = i_data_from_core;
        o_mmio_write_strobe  = o_mem_write_strobe;

        if (!i_write || (i_addr_from_core != mmio_wr_addr_r)) begin
            // Store left MEM (retired, or a new access advanced in).  Freeze
            // the pipe so the next access stays in MEM for IDLE to service,
            // then drain one cycle.
            o_stall = 1;
            NEXT = MMIO_DRAIN;
        end else begin
            // The same store is still in MEM (the pipe was held by an
            // I-cache fill on the done cycle).  Keep the request deasserted
            // and wait for it to retire.
            NEXT = MMIO_WR_RETIRE;
        end

               end

      // One-cycle gap after an MMIO transaction. The dcache's request/valid
      // lines are LEVELs that the IDLE case re-asserts immediately when the
      // next access is already in MEM (back-to-back loads/stores), and the
      // MMIO bridge returns to IDLE only after observing the request deasserted
      // for a full cycle - so without this drain cycle consecutive MMIO
      // accesses deadlock the bridge in its response state.
      //
      // CRITICAL: the pipe must stay FROZEN (o_stall=1) during the drain. The
      // serviced access advances MEM->WB on the posedge where done is seen
      // (o_stall drops to 0 in MMIO_READ/MMIO_WRITE's done branch); if the
      // drain also released the stall, the NEXT back-to-back access would
      // advance into MEM during the drain and then OUT of MEM while the FSM
      // was still in DRAIN - slipping through IDLE unserviced and corrupting
      // the MMIO stream (observed as a lost DIM_N write). Freezing here keeps
      // the pending access in MEM until IDLE sees it.
      MMIO_DRAIN : begin

        o_rd_en = 0;
        o_wr_en = 0;
        o_block_replace = 0;
        o_stall = 1;
        o_mem_read_address = {i_addr_from_core[`TAG] , i_addr_from_core[`INDEX],`OFFSET'b0};
        o_mem_read_req = 0;
        update_en = 0;
        o_amo_wr = 0;

        o_mem_write_data = i_data_from_core;
        o_mem_write_address = i_addr_from_core;
        o_mem_write_valid = 0;

        o_mmio_read_req      = 0;
        o_mmio_read_sel      = 1;
        o_mmio_read_address  = i_addr_from_core;
        o_mmio_write_valid   = 0;
        o_mmio_write_address = i_addr_from_core;
        o_mmio_write_data    = i_data_from_core;
        o_mmio_write_strobe  = o_mem_write_strobe;

        NEXT = IDLE;
               end 

    default: begin
        o_rd_en = 0;
        o_wr_en = 0;
        o_block_replace = 0;
        o_stall = 0;
        o_mem_read_address = {i_addr_from_core[`TAG] , i_addr_from_core[`INDEX],`OFFSET'b0};
        o_mem_read_req = 0;
        update_en = 0;
        o_amo_wr = 0;
        NEXT = IDLE;

        o_mem_write_data = i_data_from_core;
        o_mem_write_address = i_addr_from_core;
        o_mem_write_valid = 0;

             end

endcase

end


/////////////////////////////////////////////////
//            FAULT DETECTION BLOCK            //
/////////////////////////////////////////////////


always_comb begin : FAULT_DETECTION
    fault = 1'b0;
    case (i_size)
        2'b00 : fault = 1'b0;
        2'b01 : begin
                    if(i_addr_from_core[`BYTE_OFFSET] == 3'b111)
                    fault = 1'b1;
                    else
                    fault = 1'b0;
                end
        2'b10 : begin
                    if(i_addr_from_core[`BYTE_OFFSET] == 3'b111 || i_addr_from_core[`BYTE_OFFSET] == 3'b110 || i_addr_from_core[`BYTE_OFFSET] == 3'b101)
                    fault = 1'b1;
                    else
                    fault = 1'b0;
                end
        2'b11 : begin
                    if(i_addr_from_core[`BYTE_OFFSET] == 3'b000)
                    fault = 1'b0;
                    else
                    fault = 1'b1;
                end              
        default: fault = 1'b0;
    endcase

    if (i_amo || i_lr || i_sc) begin
        if ((i_addr_from_core[`BYTE_OFFSET] == 3'b000 && i_size == 2'b11 ) || (i_addr_from_core[`BYTE_OFFSET] == 3'b000 && i_size == 2'b10 )  || (i_addr_from_core[`BYTE_OFFSET] == 3'b100 && i_size == 2'b10 ) )
        fault = 1'b0;
        else
        fault = 1'b1;
    end
end


assign o_load_fault  = fault & i_read;
assign o_store_fault = fault & i_write;
assign o_amo_fault   = fault & i_amo;


/////////////////////////////////////////////////
//            MEM WRITE STROBE DECODER         //
/////////////////////////////////////////////////


always_comb begin : mem_write_strobe_decoder
    o_mem_write_strobe = 8'b0;
    case (i_size)
        2'b00: o_mem_write_strobe = (8'b0000_0001) << i_addr_from_core[`BYTE_OFFSET];
        2'b01: o_mem_write_strobe = (8'b0000_0011) << i_addr_from_core[`BYTE_OFFSET];
        2'b10: o_mem_write_strobe = (8'b0000_1111) << i_addr_from_core[`BYTE_OFFSET];
        2'b11: o_mem_write_strobe = (8'b1111_1111) << i_addr_from_core[`BYTE_OFFSET];
        default: o_mem_write_strobe = 8'b0;
    endcase
end

///////////////////////////////////////////////////
//            Reservation Set Comparison         //
///////////////////////////////////////////////////

always_comb begin : RES_SET_COMP
res_set_hit =0;
if (i_sc) begin
    res_set_hit = ( (VALID_RES) && (RES_SET == i_addr_from_core) && (RES_SET_SIZE == i_size));
end    
end

endmodule