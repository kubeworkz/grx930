`define TAG 63:12
`define INDEX 11:5
`define BLOCK_OFFSET 4:3
`define BYTE_OFFSET 2:0


module riscv_core_dcache_top#(
    parameter BLOCK_OFFSET      = 2,
    parameter INDEX_WIDTH       = 7,
    parameter TAG_WIDTH         = 20,
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
    input logic           [  1 :  0  ]  i_size,
    input logic           [  3 :  0  ]  i_amo_op,
    input logic                         i_amo,
    input logic                         i_lr,
    input logic                         i_sc,
    output logic                        o_stall,
    output logic [ CORE_DATA_WIDTH-1  :  0  ]  o_data_to_core,
    output logic                        o_store_fault,
    output logic                        o_load_fault,
    output logic                        o_amo_fault,




   // Interface with AXI READ CHANNEL //

    output logic [ADDR_WIDTH-1     : 0] o_mem_read_address,
    output logic                        o_mem_read_req,
    input  logic                        i_mem_read_done,
    input  logic [AXI_DATA_WIDTH-1 : 0] i_block_from_axi,
    
    // Interface with AXI WRITE CHANNEL //

    input logic                           i_mem_write_done,
    output logic                          o_mem_write_valid,
    output logic [CORE_DATA_WIDTH-1 : 0]  o_mem_write_data,
    output logic [     ADDR_WIDTH-1 : 0]  o_mem_write_address,
    output logic [                7 : 0]  o_mem_write_strobe,

    // MMIO (uncached peripheral) port
    output logic [ADDR_WIDTH-1     : 0]  o_mmio_read_address,
    output logic                        o_mmio_read_req,
    input  logic                        i_mmio_read_done,
    input  logic [CORE_DATA_WIDTH-1 : 0] i_mmio_read_data,
    output logic [ADDR_WIDTH-1     : 0]  o_mmio_write_address,
    output logic [CORE_DATA_WIDTH-1 : 0] o_mmio_write_data,
    output logic [                7 : 0] o_mmio_write_strobe,
    output logic                        o_mmio_write_valid,
    input  logic                        i_mmio_write_done
);

////////////////////////////////
//      INTERNAL REGISTERS    //
////////////////////////////////

logic                         control_to_mem_rd_en;
logic                         control_to_mem_wr_en;
logic                         control_to_mem_block_replace;
logic                         control_to_mem_amo_wr;

logic  [CORE_DATA_WIDTH -1 : 0] amo_alu_result;

// Registered copy of the AMO result. The dcache has a combinational feedback
// path FSM->o_rd_en->memory read->amo_alu->FSM (the controller samples the live
// memory output through the AMO ALU every cycle); with a defined store-data
// operand flowing into it (real AMO/SC rs2) Icarus never settles that loop.
// The result is computed in AMO_OP (when the old value is read) and consumed in
// MEM_WRITE (the next cycle), so a registered copy is functionally identical
// and breaks the zero-delay loop at the register.
logic  [CORE_DATA_WIDTH -1 : 0] amo_alu_result_reg;

always_ff @(posedge i_clk, negedge i_rst_n) begin : AMO_RESULT_REG
    if (!i_rst_n)
        amo_alu_result_reg <= 'b0;
    else
        amo_alu_result_reg <= amo_alu_result;
end

logic  [CORE_DATA_WIDTH -1 : 0] cache_mem_out , sc_out;
logic                            mmio_read_sel;


////////////////////////////////
//      BLOCK INSTANTIATION   //
////////////////////////////////

riscv_core_dcache_controller #(.TAG_WIDTH(TAG_WIDTH), .MMIO_BASE(MMIO_BASE)) dcache_controller (
    .i_clk(i_clk),
    .i_rst_n(i_rst_n),
    .i_data_from_core (i_data_from_core),
    .i_addr_from_core (i_addr_from_core),
    .i_read(i_read),
    .i_write(i_write),
    .i_amo(i_amo),
    .i_amo_alu_result(amo_alu_result_reg),
    .o_stall(o_stall),
    .o_rd_en(control_to_mem_rd_en),
    .o_wr_en(control_to_mem_wr_en),
    .o_block_replace(control_to_mem_block_replace),
    .o_amo_wr(control_to_mem_amo_wr),
    .o_mem_read_address(o_mem_read_address),
    .o_mem_read_req(o_mem_read_req),
    .i_mem_read_done(i_mem_read_done),
    .i_mem_write_done(i_mem_write_done),
    .o_mem_write_valid(o_mem_write_valid),
    .o_mem_write_address(o_mem_write_address),
    .o_mem_write_data(o_mem_write_data),
    .o_mem_write_strobe(o_mem_write_strobe),
    .o_mmio_read_address(o_mmio_read_address),
    .o_mmio_read_req(o_mmio_read_req),
    .o_mmio_read_sel(mmio_read_sel),
    .i_mmio_read_done(i_mmio_read_done),
    .o_mmio_write_address(o_mmio_write_address),
    .o_mmio_write_data(o_mmio_write_data),
    .o_mmio_write_strobe(o_mmio_write_strobe),
    .o_mmio_write_valid(o_mmio_write_valid),
    .i_mmio_write_done(i_mmio_write_done),
    .o_store_fault(o_store_fault),
    .o_load_fault(o_load_fault),
    .o_amo_fault(o_amo_fault),
    .i_size(i_size),
    .i_sc(i_sc),
    .i_lr(i_lr),
    .o_sc_result(sc_out));



riscv_core_mux3x1
#(
  .XLEN (CORE_DATA_WIDTH)
)
dcache_mux
(
  .i_mux3x1_in0 (cache_mem_out)
  ,.i_mux3x1_in1(sc_out)
  ,.i_mux3x1_in2(i_mmio_read_data)
  ,.i_mux3x1_sel({mmio_read_sel, i_sc})
  ,.o_mux3x1_out(o_data_to_core)
);


riscv_core_amo_alu amo_alu (
.i_data_from_mem(cache_mem_out),
.i_data_from_core(i_data_from_core),
.i_amo_op(i_amo_op),
.o_amo_alu_result(amo_alu_result)); 
    
    
riscv_core_dcache_memory #(.TAG_WIDTH(TAG_WIDTH)) dcache_memory (
    .i_clk(i_clk),
    .i_rst_n(i_rst_n),
    .i_data_from_core (i_data_from_core),
    .i_addr_from_core (i_addr_from_core),
    .i_size(i_size),
    .o_data_to_core(cache_mem_out),
    .i_block_from_axi(i_block_from_axi),
    .i_rd_en(control_to_mem_rd_en),
    .i_wr_en(control_to_mem_wr_en),
    .i_block_replace(control_to_mem_block_replace),
    .i_amo_alu_result(amo_alu_result),
    .i_amo_wr(control_to_mem_amo_wr) );


endmodule