`define TAG 63:12
`define INDEX 11:5
`define BLOCK_OFFSET 4:2
`define BYTE_OFFSET 1:0

module riscv_core_icache_memory #(
    parameter BLOCK_OFFSET_WIDTH = 3,
    parameter INDEX_WIDTH        = 7,
    parameter TAG_WIDTH          = 52,
    parameter CORE_DATA_WIDTH    = 32,
    parameter ADDR_WIDTH         = 64,
    parameter AXI_DATA_WIDTH     = 256
) (
// Interface with CORE//
input logic                                i_clk,
input logic                                i_rst_n,
input logic [ ADDR_WIDTH-1        :  0  ]  i_addr_from_core,
output logic [ CORE_DATA_WIDTH-1  :  0  ]  o_data_to_core,
// Interface with AXI Module //
input logic [AXI_DATA_WIDTH-1     : 0  ]   i_block_from_axi,
// Interface with CACHE Controller //
input logic                                i_rd_en,
input logic                                i_wr_en,
input logic                                i_block_replace,
input logic                                i_offset, //indicate which block index to write in
// Latched fill address: the write index must be the address of the line
// being filled, not the (possibly redirected) live fetch PC.
input logic [ ADDR_WIDTH-1        :  0  ]  i_fill_addr
);
//             LOCAL PARAMETERS              //
localparam CACHE_DEPTH = 2**INDEX_WIDTH ;
localparam BLOCK_SIZE  = 2**BLOCK_OFFSET_WIDTH ;
logic [ADDR_WIDTH-1      : 0] i_addr_from_core_1 , i_addr_from_core_2 , i_addr_from_core_3; //internal adresses
//      INTERNAL REGISTERS AND MEMORIES      //
// One 256-bit cache line per index (flattened from [BLOCK][BYTE] for Icarus).
logic [AXI_DATA_WIDTH-1 : 0] INSTR_MEM [0:CACHE_DEPTH-1];

// Registered read line: the full 256-bit line captured one cycle after
// o_rd_en, so the array is a single-port registered read (the EBR DP16KD
// pattern). The controller stalls the fetch one cycle on every hit and the
// word is selected from read_data_reg in the following (LOAD_DONE) cycle.
logic [AXI_DATA_WIDTH-1 : 0] read_data_reg;

// Initializers keep the array defined before the first reset edge (Icarus
// X-suppression only; yosys ignores `initial` on memories for BRAM inference).
// NOTE: the array is intentionally NOT reset in the always_ff -- EBR storage
// has no reset, and the controller's VALID_MEM gates every read (o_rd_en is
// only asserted on a tag hit), so stale data is never observable. This is
// what allows BRAM inference.
initial begin
    for ( int i = 0 ; i < CACHE_DEPTH  ; i=i+1 ) begin
        INSTR_MEM[i] = 'b0;
    end
end
//          assign internal addresses   //
assign i_addr_from_core_1 = i_addr_from_core + 1'b1;
assign i_addr_from_core_2 = i_addr_from_core + 2'b10;
assign i_addr_from_core_3 = i_addr_from_core + 2'b11;
//        WRITE AND REPLACEMENT BLOCK        //
// NOTE: this block deliberately has NO reset and NO async-reset sensitivity --
// EBR storage has no reset, and yosys's memory pass demotes any array written
// from an async-reset-sensitive block to registers (killing BRAM inference).
// VALID_MEM (controller) gates every read, so stale data is never observable.
always_ff @( posedge i_clk ) begin : FLUSH_WRITE_REPLACEMENT_BLOCK
    // BLOCK REPLACEMENT: a full 256-bit line is written at the fill address
    if (i_wr_en && i_block_replace) begin
        INSTR_MEM [ i_fill_addr[11 -: INDEX_WIDTH] ] <= i_block_from_axi;
    end
end
//          READ FROM MEMORY BLOCK           //
// Registered read: captures the addressed line one cycle after o_rd_en. The
// controller holds the fetch (o_stall) during the read cycle and the core
// samples o_data_to_core in the following (LOAD_DONE) cycle.
always_ff @( posedge i_clk , negedge i_rst_n ) begin : READ_MEMORY_BLOCK
    if (!i_rst_n)
        read_data_reg <= 'b0;
    else if (i_rd_en)
        read_data_reg <= INSTR_MEM [ i_addr_from_core[11 -: INDEX_WIDTH] ];
end

always_comb begin : READ_WORD_SELECT
    // READ WORD: the four bytes at byte offset addr[4:0] (little-endian),
    // selected from the REGISTERED line. NOT gated by i_rd_en: the line is
    // captured while i_rd_en is high and presented the following cycle, when
    // the controller is in LOAD_DONE (i_rd_en already low) and the core
    // samples it. The fetch PC is registered and does not advance until the
    // stall is released, so i_addr_from_core is stable across the pair.
    o_data_to_core = read_data_reg [ i_addr_from_core[4:0]*8 +: 32 ];
end
endmodule
