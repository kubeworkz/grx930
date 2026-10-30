// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Gridworkz
// tb_cache_tag_width_guard.sv -- negative control for the sim-only tag-width
// guard in riscv_core_icache_controller.sv / riscv_core_dcache_controller.sv.
//
// The controllers derive the tag storage width from INDEX_WIDTH (TAG_W =
// ADDR_WIDTH-5-INDEX_WIDTH) and only $error if the TAG_WIDTH parameter
// disagrees. Two things must therefore hold, and this TB checks both:
//
//   default (no -DWRONG_TAG_WIDTH): INDEX_WIDTH=4 with TAG_WIDTH omitted ->
//       the top's derived default (55) satisfies the guard: NO diagnostic.
//       (This is what makes the "forgot to update TAG_WIDTH" class of bug
//        impossible rather than merely detected.)
//   -DWRONG_TAG_WIDTH: INDEX_WIDTH=4, TAG_WIDTH=52 (the value the pre-fix
//       riscv_core_top hardcoded) -> the guard MUST fire, proving it is live.
//
// Compile with run_tag_width_guard.sh; both variants are pure elaboration and
// one clock edge of simulation.
`timescale 1ns/1ps
module tb_cache_tag_width_guard;

  logic         clk = 1'b0;
  logic         rst_n = 1'b0;
  logic [63:0]  addr = 64'd0;
  logic [255:0] blk = '0;
  logic         inv_valid = 1'b0;
  logic [63:0]  inv_addr = 64'd0;

  logic         ic_stall, ic_mem_req, ic_inv_ack;
  logic [31:0]  ic_data;
  logic [63:0]  ic_axi_addr;

  logic         dc_stall, dc_store_fault, dc_load_fault, dc_amo_fault;
  logic         dc_rd_req, dc_wr_valid, dc_inv_ack;
  logic         dc_mmio_rd_req, dc_mmio_wr_valid;
  logic [63:0]  dc_data, dc_rd_addr, dc_wr_addr, dc_wr_data;
  logic [63:0]  dc_mmio_rd_addr, dc_mmio_wr_addr, dc_mmio_wr_data;
  logic [7:0]   dc_wr_strobe, dc_mmio_wr_strobe;

  always #5 clk = ~clk;

  // I-cache top, INDEX_WIDTH=4 (the chip's geometry: 16 sets x 32 B = 512 B).
`ifdef WRONG_TAG_WIDTH
  riscv_core_icache_top #(.INDEX_WIDTH(4), .TAG_WIDTH(52)) u_icache (
`else
  riscv_core_icache_top #(.INDEX_WIDTH(4)) u_icache (
`endif
    .i_clk                     (clk),
    .i_rst_n                   (rst_n),
    .i_addr_from_core          (addr),
    .o_stall                   (ic_stall),
    .o_data_to_core            (ic_data),
    .o_addr_from_control_to_axi(ic_axi_addr),
    .o_mem_req                 (ic_mem_req),
    .i_mem_done                (1'b0),
    .i_block_from_axi          (blk),
    .i_inv_valid               (inv_valid),
    .i_inv_addr                (inv_addr),
    .o_inv_ack                 (ic_inv_ack)
  );

  // D-cache top, INDEX_WIDTH=4 (512 B), MMIO port tied off.
`ifdef WRONG_TAG_WIDTH
  riscv_core_dcache_top #(.INDEX_WIDTH(4), .TAG_WIDTH(52)) u_dcache (
`else
  riscv_core_dcache_top #(.INDEX_WIDTH(4)) u_dcache (
`endif
    .i_clk              (clk),
    .i_rst_n            (rst_n),
    .i_data_from_core   (64'd0),
    .i_addr_from_core   (addr),
    .i_read             (1'b0),
    .i_write            (1'b0),
    .i_size             (2'b11),
    .i_amo_op           (4'd0),
    .i_amo              (1'b0),
    .i_lr               (1'b0),
    .i_sc               (1'b0),
    .o_stall            (dc_stall),
    .o_data_to_core     (dc_data),
    .o_store_fault      (dc_store_fault),
    .o_load_fault       (dc_load_fault),
    .o_amo_fault        (dc_amo_fault),
    .o_mem_read_address (dc_rd_addr),
    .o_mem_read_req     (dc_rd_req),
    .i_mem_read_done    (1'b0),
    .i_block_from_axi   (blk),
    .i_mem_write_done   (1'b0),
    .o_mem_write_valid  (dc_wr_valid),
    .o_mem_write_data   (dc_wr_data),
    .o_mem_write_address(dc_wr_addr),
    .o_mem_write_strobe (dc_wr_strobe),
    .o_mmio_read_address(dc_mmio_rd_addr),
    .o_mmio_read_req    (dc_mmio_rd_req),
    .i_mmio_read_done   (1'b0),
    .i_mmio_read_data   (64'd0),
    .o_mmio_write_address(dc_mmio_wr_addr),
    .o_mmio_write_data  (dc_mmio_wr_data),
    .o_mmio_write_strobe(dc_mmio_wr_strobe),
    .o_mmio_write_valid (dc_mmio_wr_valid),
    .i_mmio_write_done  (1'b0),
    .i_inv_valid        (inv_valid),
    .i_inv_addr         (inv_addr),
    .o_inv_ack          (dc_inv_ack)
  );

  initial begin
    rst_n = 1'b0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);
    $display("GUARD_CONTROL_DONE");
    $finish;
  end

endmodule
