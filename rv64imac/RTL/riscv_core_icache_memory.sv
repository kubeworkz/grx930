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
// Initializers keep the combinational read defined before the first reset edge.
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
always @( posedge i_clk , negedge i_rst_n ) begin : FLUSH_WRITE_REPLACEMENT_BLOCK
    if (!i_rst_n) begin
        // Clear ALL Entries //
            for ( int i = 0 ; i < CACHE_DEPTH  ; i=i+1 ) begin
                INSTR_MEM[i] <= 'b0;
            end
    end
    else begin
        // BLOCK REPLACEMENT // 
        if (i_wr_en && i_block_replace) begin
            INSTR_MEM [ i_fill_addr[11 -: INDEX_WIDTH] ] <= i_block_from_axi;
        end
    end    
end
//          READ FROM MEMORY BLOCK           //
always_comb begin : READ_MEMORY_BLOCK
    o_data_to_core = 'b0;
    if (i_rd_en) begin
        // READ WORD: the four bytes at byte offset addr[4:0] (little-endian).
        o_data_to_core = INSTR_MEM [ i_addr_from_core[11 -: INDEX_WIDTH] ][ i_addr_from_core[4:0]*8 +: 32 ];
    end
end
endmodule
