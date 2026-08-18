`define TAG 63:12
`define INDEX 11:5
`define BLOCK_OFFSET 4:3
`define BYTE_OFFSET 2:0


module riscv_core_dcache_memory #(
    parameter BLOCK_OFFSET      = 2,
    parameter INDEX_WIDTH       = 7,
    parameter TAG_WIDTH         = 52,
    parameter CORE_DATA_WIDTH   = 64,
    parameter ADDR_WIDTH        = 64,
    parameter AXI_DATA_WIDTH    = 256,
    parameter FIFO_ENTRY_WIDTH  = 128
) (


// Interface with CORE//
input logic                                i_clk,
input logic                                i_rst_n,
input logic [ ADDR_WIDTH-1        :  0  ]  i_addr_from_core,
input logic [ CORE_DATA_WIDTH-1   :  0  ]  i_data_from_core,
input logic                  [  1 :  0  ]  i_size,
input logic [ CORE_DATA_WIDTH-1   :  0  ]  i_amo_alu_result,
output logic [ CORE_DATA_WIDTH-1  :  0  ]  o_data_to_core,



// Interface with AXI Module //

input logic [AXI_DATA_WIDTH-1     : 0  ]   i_block_from_axi,


// Interface with CACHE Controller //

input logic                                i_rd_en,
input logic                                i_wr_en,
input logic                                i_amo_wr,
input logic                                i_block_replace
);




///////////////////////////////////////////////
//             LOCAL PARAMETERS              //
///////////////////////////////////////////////

localparam CACHE_DEPTH = 2**INDEX_WIDTH ;
localparam BLOCK_SIZE  = 2**BLOCK_OFFSET ;

///////////////////////////////////////////////
//      INTERNAL REGISTERS AND MEMORIES      //
///////////////////////////////////////////////

// One 256-bit cache line per index. The line is stored as a single entry so
// the whole 256-bit line can be written at one address with per-byte enables
// (the EBR DP16KD byte-enable pattern): a line fill writes all 32 bytes, a
// data/AMO write writes the decoded lane range (see be_all below). Reads are
// REGISTERED (EBR reads have no combinational path); the controller stalls
// the core one cycle on every cache read (see riscv_core_dcache_controller).
logic [AXI_DATA_WIDTH-1 : 0] DATA_MEM [0: CACHE_DEPTH-1];

// Registered read word: the full 256-bit line read one cycle after o_rd_en.
logic [AXI_DATA_WIDTH-1 : 0] read_data_reg;

// Initializers keep the array defined before the first reset edge (Icarus
// X-suppression only; yosys ignores `initial` on memories for BRAM inference).
// NOTE: the array is intentionally NOT reset in the always_ff -- EBR storage
// has no reset, and the controller's VALID_MEM gates every read, so stale
// data is never observable. This is what allows BRAM inference.
initial begin
    for ( int i = 0 ; i < CACHE_DEPTH  ; i=i+1 ) begin
        DATA_MEM[i] = 'b0;
    end
end

///////////////////////////////////////////////
//    DECODED BYTE-LANE WRITE ENABLES        //
///////////////////////////////////////////////

// The write data is placed at its byte lane by ONE shared barrel shift and
// each of the 32 byte lanes gets a decoded enable, so the per-bit position
// muxes of the old implementation (the ~366K-LUT write path) collapse into a
// single decoder + 32:1... 8:1 shift tree (~1K LUTs total).

logic [4:0]      wr_base;          // byte lane base of the access
logic [3:0]      wr_nbytes;        // 1/2/4/8 bytes (4 bits: 8 must fit!)
logic [63:0]     wr_data64;        // value placed at wr_base
logic [255:0]    wr_shifted;       // wr_data64 barrel-shifted to the base lane
logic [31:0]     be_all;           // per-lane write enables (fill = all ones)
logic [255:0]    wr_data_all;      // per-lane write data (fill = block line)

always_comb begin : WRITE_DECODE
    // dword accesses are word-aligned; byte/half/word are byte-aligned
    wr_base = (i_size == 2'b11) ? {i_addr_from_core[4:3], 3'b0}
                                : i_addr_from_core[4:0];

    unique case (i_size)
        2'b00:   wr_nbytes = 4'd1;
        2'b01:   wr_nbytes = 4'd2;
        2'b10:   wr_nbytes = 4'd4;
        2'b11:   wr_nbytes = 4'd8;
        default: wr_nbytes = 4'd1;
    endcase

    // AMO word writes [31:0] at the base lane; all other writes use the full
    // 64-bit value (byte/half/word use the low bits; dword uses all).
    if (i_amo_wr && (i_size == 2'b10))
        wr_data64 = {32'b0, i_amo_alu_result[31:0]};
    else if (i_amo_wr)
        wr_data64 = i_amo_alu_result;
    else
        wr_data64 = i_data_from_core;

    // One shared shift instead of per-bit position muxes.
    wr_shifted = {192'b0, wr_data64} << (wr_base * 8);

    for (int b = 0; b < 32; b++) begin
        be_all[b]        = i_block_replace | ((b >= wr_base) && (b < (wr_base + wr_nbytes)));
        wr_data_all[b*8 +: 8] = i_block_replace ? i_block_from_axi[b*8 +: 8]
                                                : wr_shifted[b*8 +: 8];
    end
end

///////////////////////////////////////////////
//        WRITE AND REPLACEMENT BLOCK        //
///////////////////////////////////////////////

// NOTE: this block deliberately has NO reset and NO async-reset sensitivity --
// EBR storage has no reset, and yosys's memory pass demotes any array written
// from an async-reset-sensitive block to registers (killing BRAM inference).
// VALID_MEM (controller) gates every read, so stale data is never observable.
always_ff @( posedge i_clk ) begin : FLUSH_WRITE_REPLACEMENT_BLOCK
    if (i_wr_en) begin
        // Single write port at the line address with per-byte enables.
        for (int b = 0 ; b < 32 ; b = b + 1) begin
            if (be_all[b])
                DATA_MEM [ i_addr_from_core[11 -: INDEX_WIDTH] ][ b*8 +: 8 ] <= wr_data_all[b*8 +: 8];
        end
    end
end


///////////////////////////////////////////////
//          READ FROM MEMORY BLOCK           //
///////////////////////////////////////////////

// Registered read: captures the addressed line one cycle after o_rd_en. The
// controller holds the core (o_stall) during the read cycle and the core
// samples o_data_to_core in the following (LOAD_DONE) cycle.
always_ff @( posedge i_clk , negedge i_rst_n ) begin : READ_MEMORY_BLOCK
    if (!i_rst_n)
        read_data_reg <= 'b0;
    else if (i_rd_en)
        read_data_reg <= DATA_MEM [ i_addr_from_core[11 -: INDEX_WIDTH] ];
end

always_comb begin : READ_SIZE_SELECT
    unique case (i_size)
        // READ BYTE
         2'b00   : o_data_to_core = read_data_reg [ i_addr_from_core[4:0]*8 +: 8  ];

         // READ HALFWORD
         2'b01   : o_data_to_core = read_data_reg [ i_addr_from_core[4:0]*8 +: 16 ];

         // READ WORD
         2'b10   : o_data_to_core = read_data_reg [ i_addr_from_core[4:0]*8 +: 32 ];

         // READ DOUBLEWORD
         2'b11   : o_data_to_core = read_data_reg [ i_addr_from_core[4:3]*64 +: 64 ];

        default : o_data_to_core = 'b0;
    endcase
end




endmodule
