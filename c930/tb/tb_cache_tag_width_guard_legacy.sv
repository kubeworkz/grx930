// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Gridworkz
// tb_cache_tag_width_guard_legacy.sv -- negative control for the tag-width
// guard, generation-independent: the guard lives in the controllers and only
// needs INDEX_WIDTH / TAG_WIDTH, so the controllers are instantiated with
// unconnected ports (no interface version is assumed).
//
//   A (no -DWRONG_TAG_WIDTH): INDEX_WIDTH=4 with the DERIVED tag width
//       (64-5-4 = 55) -> guard silent, sim completes.
//   B (-DWRONG_TAG_WIDTH): INDEX_WIDTH=4, TAG_WIDTH=52 (the pre-fix hardcoded
//       value) -> the guard MUST fire for every controller present.
//
// Compile with run_cache_index_alias_legacy.sh; -DNO_ICACHE skips the icache
// instance for the atomic_dcaches archive, which has no icache copy.
`timescale 1ns/1ps
module tb_cache_tag_width_guard_legacy;

  localparam int W = 4;

`ifdef WRONG_TAG_WIDTH
  riscv_core_dcache_controller #(.INDEX_WIDTH(W), .TAG_WIDTH(52)) u_dc ();
`else
  riscv_core_dcache_controller #(.INDEX_WIDTH(W), .TAG_WIDTH(64-5-W)) u_dc ();
`endif

`ifndef NO_ICACHE
`ifdef WRONG_TAG_WIDTH
  riscv_core_icache_controller #(.INDEX_WIDTH(W), .TAG_WIDTH(52)) u_ic ();
`else
  riscv_core_icache_controller #(.INDEX_WIDTH(W), .TAG_WIDTH(64-5-W)) u_ic ();
`endif
`endif

  initial begin
    #100;
    $display("GUARD_CONTROL_DONE");
    $finish;
  end

endmodule
