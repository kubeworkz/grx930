# The cache index/tag split, in every rv64imac cache copy

**Found** 2026-10-11 in the tapeout tree
(`c930/asic_gf180mcu/openlane2_rtl/src`, where it was fixed first: literal
`addr[11:5]` tag select over an `INDEX_WIDTH`-wide data array aliased
`2**(7-INDEX_WIDTH)` tag entries onto one data line). **Applied the same day to
the four cache trees under `rv64imac/`** so no instantiation at any width can
serve a wrong line. **Gates:**
`tb/run_cache_index_alias.sh <tree>` and `tb/run_tag_width_guard.sh <tree>` (the
present-generation tests), `tb/run_cache_index_alias_legacy.sh <tree> <case>`
(the older generations), and `tb/run_cache_split_lockstep.sh [ROOT]` — the
text-level lockstep that holds all 27 cache sources and all 4 core tops across
the five trees below to one split surface: surface equality against
`rv64imac/RTL` of the declarations *and* of every `.INDEX_WIDTH(...)` /
`.TAG_WIDTH(...)` override, a buggy-literal scan, the canonical anchors (so a
joint revert is caught too), and one derived `.INDEX_WIDTH`/`.TAG_WIDTH` pair
per cache-top instantiation. It supersedes `tb/run_fpga_cache_lockstep.sh`,
which covered only the FPGA pair.

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
  `rv64imac/RTL/riscv_core_top.sv` and its tapeout copy use
  `64 - 5 - <ICACHE|DCACHE>_INDEX_WIDTH`; `FPGA/src/riscv_core_top.sv` writes
  `64 - 5 - 7`, and the Branch_Prediction variant's stale `.TAG_WIDTH(20)`
  became `64 - 5 - 7` too.

Files (27 cache sources + 4 core tops), which is the inventory
`tb/run_cache_split_lockstep.sh` walks:

| tree | copies |
|---|---|
| `rv64imac/RTL` (the live tree: `c930/asic/Makefile`, `asic_gf180mcu/Makefile`, the Xilinx project) | dcache + icache, controller/memory/top |
| `rv64imac/RTL/caches` | dcache + icache, controller/memory/top |
| `rv64imac/RTL/caches/atomic_dcaches` | dcache, controller/memory/top |
| `rv64imac/FPGA/src` | dcache + icache, controller/memory/top |
| `c930/asic_gf180mcu/openlane2_rtl/src` (the tapeout tree, fixed first) | dcache + icache, controller/memory/top |

plus the four core tops: `rv64imac/RTL/riscv_core_top.sv` and
`c930/asic_gf180mcu/openlane2_rtl/src/riscv_core_top.sv` (named
`ICACHE_INDEX_WIDTH`/`DCACHE_INDEX_WIDTH` = 7), and the FPGA and
Branch_Prediction variants (literal `64 - 5 - 7`; the Branch_Prediction top
instantiates the dcache only).

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
* **Static invariant** — what was a one-off sweep over the 21 files of the
  four `rv64imac/` trees is now the standing gate
  `tb/run_cache_split_lockstep.sh` over all 27 copies plus the 4 core tops: no
  literal `63:12` / `[11:5]` / `[11 -:`, and every file carries the derived
  definition (plus `TAG_W` and the `$error` guard in every controller, the
  derived `TAG_WIDTH` default in every top, the two
  `.INDEX_WIDTH(INDEX_WIDTH)`/`.TAG_WIDTH(TAG_WIDTH)` pairs each cache top uses
  to pass the split into its controller and memory, and a derived
  `.INDEX_WIDTH`/`.TAG_WIDTH` pair per instantiation in the core tops).

## Notes / remaining limitations

* `tb/run_cache_split_lockstep.sh` is text-level: it locks the split surface and
  the tops' derived overrides, not whole files (these trees are deliberate
  forks), and it needs no simulator. Everything it enforces except the tapeout
  tree is tracked in git — the four `rv64imac` trees and the RTL, FPGA and
  Branch_Prediction core tops must be present, and a copy missing counts as a
  failure; only the tapeout tree (untracked, like the rest of
  `c930/asic_gf180mcu/`) reports `SKIP` when absent. Evidence: `OVERALL: PASS`,
  exit 0 on the working trees, and
  19 scratch-copy controls with each exit status checked: an untouched baseline
  (`PASS`, exit 0); a one-sided define revert in the `caches` tree and in the
  FPGA tree; a use-site `[11:5]`; a stale `.TAG_WIDTH(20)` in the
  Branch_Prediction top; a stale `.TAG_WIDTH(52)` override and a deleted
  override in a cache top; a deleted override in the RTL top; an instantiation
  left without a pair; a changed `TAG_WIDTH` value; a changed `INDEX_WIDTH`
  default; a changed named `ICACHE_INDEX_WIDTH` default in the RTL top; a
  deleted `$error` guard; drift inside the tapeout tree (exit 1 when it is
  present); a missing tapeout tree (`SKIP`, still exit 0); a missing FPGA tree
  and a missing `caches` tree (exit 1); and —
  the case the surface leg cannot see — the **joint revert of all 27 copies**,
  which the anchors catch (exit 1, zero surface diffs). Re-worded comments and
  CRLF do not trip it (exit 0).
* The control copies under `c930/build/prefix_cache_sim/` are throwaway, and
  the pre-fix content of every enforced copy is recoverable with
  `git show <rev>:<path>`.
* No netlist impact: the tapeout tree was already fixed; this only keeps the
  reference trees from reintroducing the defect. `make sim`, `make
  dcache_mmio_hold` and the OL2 source tree are unaffected by this change.
