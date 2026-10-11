# The cache index/tag split, in every rv64imac cache copy

**Found** 2026-10-11 in the tapeout tree
(`c930/asic_gf180mcu/openlane2_rtl/src`, where it was fixed first: literal
`addr[11:5]` tag select over an `INDEX_WIDTH`-wide data array aliased
`2**(7-INDEX_WIDTH)` tag entries onto one data line). **Applied the same day to
the four cache trees under `rv64imac/`** so no instantiation at any width can
serve a wrong line. **Gates:**
`tb/run_cache_index_alias.sh <tree>` and `tb/run_tag_width_guard.sh <tree>` (the
present-generation tests), `tb/run_cache_index_alias_legacy.sh <tree> <case>`
(the older generations).

## What changed, per copy

For dcache and icache, in `controller`, `memory` and `top`:

* both selects derive from the module parameters — no literals left in code:

      `define TAG          ADDR_WIDTH-1 : 5+INDEX_WIDTH
      `define DCACHE_INDEX 5 +: INDEX_WIDTH       (icache: ICACHE_INDEX)

  Dcache and icache macros got distinct names so the two files can be compiled
  together without one clobbering the other (`INDEX 11:5` used to be shared).
* controllers size the tag array from the split —
  `localparam TAG_W = ADDR_WIDTH - 5 - INDEX_WIDTH` — so a stale `TAG_WIDTH`
  can no longer truncate the tag compare, and `$error` in simulation if an
  explicitly overridden `TAG_WIDTH` disagrees (`ifndef SYNTHESIS`).
* memories index the data array with `5 +: INDEX_WIDTH`, never `11 -: ...` or
  the literal `11:5` (the present-generation memory carried the literal from
  the wrong end of the word — that was the aliasing bug).
* tops derive the `TAG_WIDTH` default from the split
  (`ADDR_WIDTH - 5 - INDEX_WIDTH`, declared after `ADDR_WIDTH` so the default
  never forward-references a later parameter) and pass `INDEX_WIDTH` down to
  their controller and memory (the older copies previously left both at the
  default 7 while believing they were running at another width).
* the core tops that instantiate the caches pass a derived tag width:
  `rv64imac/RTL/riscv_core_top.sv` and `FPGA/src/riscv_core_top.sv` use
  `64 - 5 - <W>`; the Branch_Prediction variant's stale `.TAG_WIDTH(20)` became
  `64 - 5 - 7`.

Files (21 cache sources + 3 core tops):

| tree | copies |
|---|---|
| `rv64imac/RTL` (the live tree: `c930/asic/Makefile`, `asic_gf180mcu/Makefile`, the Xilinx project) | dcache + icache, controller/memory/top |
| `rv64imac/RTL/caches` | dcache + icache, controller/memory/top |
| `rv64imac/RTL/caches/atomic_dcaches` | dcache, controller/memory/top |
| `rv64imac/FPGA/src` | dcache + icache, controller/memory/top |

The one-shot transform (idempotency refused on purpose, `--check` mode
available) is kept at `Claude outputs/cache_index_tag_param_fix.py`.

## Evidence

* **Live tree, present-generation regressions** (`INDEX_WIDTH = 4`):
  `run_cache_index_alias.sh ../../rv64imac/RTL` → both caches
  `RESULT: PASS ... fill addresses decomposed correctly`, `OVERALL: PASS`,
  exit 0. `run_tag_width_guard.sh` → A (derived default) silent, B (explicit
  `TAG_WIDTH=52`) fires for both controllers, exit 0.
* **Control for that tree:** the same tests against the pre-fix sources (staged
  from git into `c930/build/prefix_cache_sim/rtl`) fail with the wrong-line
  signature — `icache addr=0000…: got 000000a0 expected 00000000 (wrong line
  served on HIT)` and the same for dcache — and guard control B reports the
  check dead. The regressions discriminate on this tree.
* **Older generations** (Icarus cannot compile them at all — their packed
  three-dimensional memories index with non-constant part-selects, which fails
  identically on the pre-fix sources; that is why the present generation's
  memory was flattened "for Icarus"). The new legacy regressions run under
  Verilator 5.051 from the repo toolchain
  (`c930/toolchain/oss-cad-suite`, Windows `verilator_bin` generating C++,
  built and run with WSL `g++`; the runner scripts this):

      SIM=verilator ./run_cache_index_alias_legacy.sh ../../rv64imac/RTL/caches                caches
      SIM=verilator ./run_cache_index_alias_legacy.sh ../../rv64imac/RTL/caches/atomic_dcaches atomic
      SIM=verilator ./run_cache_index_alias_legacy.sh ../../rv64imac/FPGA/src                  fpga

  All three: `RESULT: PASS` for dcache (and icache where present) at
  `INDEX_WIDTH = 4` **and** 6 (`EXTRA_DEFS=-DW_OVERRIDE=6`), plus guard A
  silent / guard B firing for every controller present — `OVERALL: PASS`.
  Honest scoping: on these two older generations the pre-fix code also passes
  the W = 4 alias test (its literal 7-bit select truncates to the correct bits
  at that width), so for them this is a no-behaviour-change regression plus
  width-robustness; at W = 6 the literal select indexes a 64-entry array with
  7-bit values, which is what the derived split removes.
* **Integration:** the whole `rv64imac/RTL` core elaborates under iverilog
  (`-s riscv_core_top`, exit 0); `FPGA/src` elaborates under Verilator
  (`--lint-only --top-module riscv_core_top_2`, no errors); the
  Branch_Prediction variant's error signature is unchanged pre/post edit (its
  pre-existing missing `riscv_core_imem` blocks full elaboration — not touched
  here).
* **Static invariant** over all 21 cache files (comments stripped): no literal
  `63:12`, `[11:5]`, `[11 -:`, no bare `INDEX`/`INDEXI`/`TAGI`/
  `BLOCK_OFFSET`/`BYTE_OFFSET`/`OFFSETI` macro uses remain, and every file
  carries the derived definition (plus `TAG_W` and the `$error` guard in every
  controller, and the derived `TAG_WIDTH` + `.INDEX_WIDTH(INDEX_WIDTH)` in
  every top).

## Notes / remaining limitations

* The control copies under `c930/build/prefix_cache_sim/` are throwaway
  (regenerate with `git show HEAD:...`); `FPGA/src` is untracked in git, so it
  has no pre-fix copy to diff against.
* No netlist impact: the tapeout tree was already fixed; this only keeps the
  reference trees from reintroducing the defect. `make sim`, `make
  dcache_mmio_hold` and the OL2 source tree are unaffected by this change.
