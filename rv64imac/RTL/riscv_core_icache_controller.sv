`define TAG 63:12
`define INDEX 11:5
`define BLOCK_OFFSET 4:2
`define BYTE_OFFSET 1:0
`define OFFSET 5

module riscv_core_icache_controller #(
    parameter BLOCK_OFFSET_WIDTH = 2,
    parameter INDEX_WIDTH        = 7,
    parameter TAG_WIDTH          = 52,
    parameter CORE_DATA_WIDTH    = 32,
    parameter ADDR_WIDTH         = 64,
    parameter AXI_DATA_WIDTH     = 256
) (
    // Interface with CORE//
    input logic                         i_clk,
    input logic                         i_rst_n,
    input logic [ADDR_WIDTH-1      : 0] i_addr_from_core ,
    output logic                        o_stall,
    // Interface with CACHE MEM //
    output logic                         o_rd_en,
    output logic                         o_wr_en,
    output logic                         o_block_replace,
    // Interface with AXI Module //
    output logic [ADDR_WIDTH-1     : 0] o_addr_from_control_to_axi,
    output logic                        o_mem_req,
    input  logic                        i_mem_done,
    output logic                        o_offset,
    // Latched address of the line being filled (stable across the fill).
    output logic [ADDR_WIDTH-1     : 0] o_fill_addr
);
//             LOCAL PARAMETERS              //
localparam CACHE_DEPTH = 2**INDEX_WIDTH ;
//      INTERNAL REGISTERS AND MEMORIES      //
logic [(TAG_WIDTH-1):0] TAG_MEM  [0:CACHE_DEPTH-1];
logic                      VALID_MEM [0:CACHE_DEPTH-1];
enum logic [1:0] {
    IDLE           = 2'b00,
    MEM_REQ        = 2'b01,
    UPDATE_CACHE   = 2'b10,
    LOAD_DONE      = 2'b11
} STATE , NEXT ;   // STATE/NEXT initialized to IDLE in the initial block below
logic                      update_en;
logic                      tag_hit_1 , tag_hit_2 , over_f , s1 , s2 , miss ;
logic [ADDR_WIDTH-1      : 0] i_addr_from_core_next_block;
// Latched address of the line being filled. The fetch PC (i_addr_from_core)
// can move while the fill is in flight (e.g. a taken branch redirecting during
// an instruction-cache miss), so the fill target must be held stable from the
// moment MEM_REQ is entered until UPDATE_CACHE completes; otherwise the block
// and tag get written to the wrong index and the cache is corrupted.
logic [ADDR_WIDTH-1      : 0] fill_addr = 'b0;
logic                      fill_s2 = 1'b0;   // s2 condition captured at MEM_REQ entry
// Fetch address served by the current registered read. The word is captured
// into read_data_reg one cycle after the IDLE hit and presented from LOAD_DONE;
// LOAD_DONE HOLDS (stall released, word still valid) until the fetch PC
// advances -- i.e. until the pipeline actually captured the instruction. This
// guarantees a both-stalls-released window with the dcache (whose registered
// read also needs the pipeline to advance), preventing the two period-2
// hit-stall loops from phase-locking in anti-phase and deadlocking.
logic [ADDR_WIDTH-1      : 0] served_pc = 'b0;
// Initializers keep the combinational FSM/tag logic defined before the first
// reset edge (Icarus would otherwise cascade X through the cache at t=0).
initial begin
    for ( int i = 0 ; i < CACHE_DEPTH  ; i=i+1 ) begin
        TAG_MEM[i] = 'b0;
        VALID_MEM[i] = 1'b0;
    end
    STATE = IDLE;
    NEXT = IDLE;
end
//    ASSIGNING NEXT STATE AND UPDATE BLOCK    //
always_ff @( posedge i_clk , negedge i_rst_n ) begin : NEXT_STATE_ASSIGN_FLUSH_UPDATE_BLOCK
    if (!i_rst_n) begin
        // Clear ALL Valid Entries //
        for ( int i = 0 ; i < CACHE_DEPTH  ; i=i+1 ) begin
            VALID_MEM[i] <= 0;
        end
        STATE <= IDLE;
        fill_addr <= 'b0;
        fill_s2 <= 1'b0;
        served_pc <= 'b0;
    end
    else 
    begin
        STATE <= NEXT ;
        // Latch the fill target when a miss is accepted in IDLE (only the
        // IDLE->MEM_REQ transition; MEM_REQ keeps NEXT==MEM_REQ while waiting
        // for the line and must not re-latch a redirected fetch PC).
        if (STATE == IDLE && NEXT == MEM_REQ) begin
            fill_addr <= s2 ? i_addr_from_core_next_block : i_addr_from_core;
            fill_s2   <= s2;
        end
        // Latch the fetch PC served by a hit (IDLE->LOAD_DONE transition).
        // LOAD_DONE compares the live PC against this to decide hold vs
        // transition; the PC is frozen while the hit stalls, so this is the
        // address the registered read serves.
        if (STATE == IDLE && NEXT == LOAD_DONE) begin
            served_pc <= i_addr_from_core;
        end
        // UPDATE TAG and VALID MEM in case of BLOCK REPLACEMENT //
        if (update_en) begin
            TAG_MEM       [  fill_addr[`INDEX]   ] <= fill_addr[`TAG];
            VALID_MEM     [  fill_addr[`INDEX]   ] <= 1'b1;
        end
    end
end
//            TAG COMPARISON BLOCK IF THE SAME BLOCK             //
assign tag_hit_1 = ((TAG_MEM[i_addr_from_core[`INDEX]] == i_addr_from_core[`TAG]) &&  VALID_MEM[i_addr_from_core[`INDEX]]); 
//            DETECT IF IT'S NEEDED TO TAKE TWO BYTES FROM THE NEXT BLOCK   //
assign over_f = ((i_addr_from_core[`BLOCK_OFFSET]==3'b111) && (i_addr_from_core[`BYTE_OFFSET]==2'b10));
//            ADD 2 TO GET THE NEW INDEX AND NEW TAG IN CASE OF OVER_F  //
assign i_addr_from_core_next_block = i_addr_from_core + 2'b10 ;
//             TAG COPARISON BLOCK IN CASE OF NEXT BLOCK        //
assign tag_hit_2 = ((TAG_MEM[i_addr_from_core_next_block[`INDEX]] == i_addr_from_core_next_block[`TAG]) &&  VALID_MEM[i_addr_from_core_next_block[`INDEX]]); 
//             s1 IS THE CONDITION OF CACHE MISS IN THE SAME BLOCK  //
assign s1 = !(tag_hit_1);
//             s2 IS THE CONDITION OF MISS IN THE NEXT BLOCK IN CASE OF OVER_F  //
assign s2 = (( over_f ) && !( tag_hit_2 ));
//             MISS CONDITION WILL HAPPEN IF S1 HAPPEN OR S2 HAPPEN //
assign miss = (s1) || (s2);
//            FSM TRANSITION BLOCK             //
always_comb begin : FSM_TRANSITION_BLOCK
        // One-shot t=0 probe: Icarus never settles a marginal zero-delay
        // combinational loop in the dcache at time 0 (an event-scheduling
        // pathology, not RTL logic); a $display in any comb block at t=0
        // perturbs the scheduling and lets the sim advance. Sim-only: yosys
        // defines SYNTHESIS and skips this (it cannot parse $time here).
`ifndef SYNTHESIS
        if ($time == 0) $display("[T0P] icache FSM probe");
`endif
// DEFAULT VALUES //
o_rd_en = 0;
o_wr_en = 0;
o_block_replace = 0;
o_stall = 0;
o_addr_from_control_to_axi = 64'b0;
o_mem_req = 0;
update_en = 0;
o_offset = 0;
o_fill_addr = fill_addr;
NEXT = STATE;
case (STATE)
    IDLE   : begin //always read no write from core
        // DEFAULT VALUES FOR IDLE//
        o_rd_en = 0;
        o_wr_en = 0;
        o_block_replace = 0;
        o_stall = 0;
        o_mem_req = 0;
        update_en = 0;
        // READING SCINARIOs //
            if (!miss) begin // READ HIT (registered read: stall 1 cycle so the
                             // core samples the word from read_data_reg in LOAD_DONE)
                o_rd_en = 1;
                o_stall = 1;
                NEXT = LOAD_DONE;
            end
            else begin // READ MISS
                o_stall = 1;
                o_mem_req = 1;
                if(s1)      //if s1 then get the block from the start   //
                    o_addr_from_control_to_axi = {i_addr_from_core[`TAG],i_addr_from_core[`INDEX],`OFFSET'b0};
                else if (s2)    //if s2 then get the next block from the start  //
                    o_addr_from_control_to_axi = {i_addr_from_core_next_block[`TAG],i_addr_from_core_next_block[`INDEX],`OFFSET'b0};
                NEXT = MEM_REQ;
            end        
    end
    MEM_REQ : begin
        o_rd_en = 0;
        o_wr_en = 0;
        o_block_replace = 0;
        o_stall = 1;
        // Use the latched fill address, not the live fetch PC (which may have
        // been redirected by a taken branch while the fill was in flight).
        o_addr_from_control_to_axi = {fill_addr[`TAG],fill_addr[`INDEX],`OFFSET'b0};
        o_mem_req = 1;
        update_en = 0;
        o_fill_addr = fill_addr;
        if (i_mem_done) begin
            o_mem_req = 0;
            NEXT = UPDATE_CACHE;
        end
    end
    UPDATE_CACHE : begin
        o_rd_en = 0;
        o_wr_en = 1;
        o_block_replace = 1;
        // to allocate which to write in //
        o_offset = fill_s2;
        ///////////////////////////////////
        o_stall = 1;
        o_addr_from_control_to_axi = 64'b0;
        o_mem_req = 0;
        update_en = 1;
        NEXT = IDLE;
    end

    LOAD_DONE : begin

        // The registered read from the previous cycle is valid now. Release
        // the stall and HOLD while the fetch PC is unchanged -- the word stays
        // valid and the pipeline captures it at the first posedge where every
        // other stall (e.g. the dcache's registered-read stall) is also
        // released. If the fetch PC has advanced (the pipeline captured the
        // word, or a redirect fired), stall one cycle so the now-stale word is
        // not captured into IF/ID, then start the next fetch in IDLE.
        if (i_addr_from_core == served_pc) begin
            o_stall = 0;
            NEXT = LOAD_DONE;
        end
        else begin
            o_stall = 1;
            NEXT = IDLE;
        end
    end

    default: begin
        o_rd_en = 0;
        o_wr_en = 0;
        o_block_replace = 0;
        o_stall = 0;
        o_addr_from_control_to_axi = 64'b0;
        o_mem_req = 0;
        update_en = 0;
        NEXT = IDLE;
        end
endcase
end
endmodule