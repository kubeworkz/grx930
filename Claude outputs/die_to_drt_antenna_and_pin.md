# The die, past `GRT-0183`, to detailed routing — what it takes (2026-10-14)

Two arms were run: a **lever on the pinned build** (the four antenna-repair settings
LibreLane exposes) and an **engine pin** (the post-26Q4 OpenROAD that contains the FastRoute
fixes). Headline: the lever clears the abort on the pinned engine and carries the flow into
`OpenROAD.DetailedRouting`, whose first pass is measured in §4.2; the pin *does* fix the
abort at the step level, and at flow level it is stopped by a second, unrelated
incompatibility in LibreLane's own scripts — which has a named upstream fix (PR #1023, in
LibreLane ≥ 3.0.13). That fix is now backported and verified to apply in-container (§3.4),
so the pin path is one opt-in flag away from running end-to-end once the DRT arm has freed
the box.

## 1. The blocker, restated in one place

With `GRT_ADJUSTMENT: 0.1` landed, the die's global routing completes and converges, and the
resume then dies in the Antenna Repair stage. Verbatim, from the step that dies
(`runs/die01/04-openroad-repairantennas/1-openroad-diodeinsertion/openroad-diodeinsertion.log`):

```
+ repair_antennas gf180mcu_fd_sc_mcu7t5v0__antenna -iterations 3 -ratio_margin 10 -allow_congestion
[INFO GRT-0012] Found 2979 antenna violations.
[INFO GRT-0302] Inserted 3846 jumpers for 2080 nets.
[INFO GRT-0012] Found 1299 antenna violations.
[WARNING GRT-0243] Unable to repair antennas on net with diodes.
[INFO GRT-0015] Inserted 2522 diodes.
[ERROR GRT-0183] Net _167563_: heap underflow during 3D maze routing.
Error: antenna_repair.tcl, 27 GRT-0183
```

Source database, named by the step's own `state_in.json`/`_env.tcl` (`CURRENT_ODB`):
`runs/die01/01-openroad-globalrouting/chip_top.odb` (243,988,835 B). Engine: the pin
LibreLane ships, `openroad dcf36133a369abc8f3c5e5738cd4d82e4903c0e0`, rev-date
**2026-02-17**, inside `ghcr.io/wafer-space/gf180mcu-precheck` (LibreLane v3.1.0.dev1).

Both arms drive *that* call on *that* database — `ws/probe/antenna_probe.tcl` builds the
argument list exactly as LibreLane's `antenna_repair.tcl` does, `ws/probe/antenna_probe.sh`
runs one variant per OpenROAD process, `build/antenna_probe_chain.sh` gates and logs it.
Control: the pinned build under the harness reproduces the flow exactly — *2979 violations,
3846 jumpers for 2080 nets, abort on `_167563_`* — so the instrument is the same one.

## 2. Arm A — levers on the pinned build: one of them passes, at a cost

| variant | iters | margin | jumper_only | diode_only | catch rc | GRT-0183 | jumpers | diodes | violations left | wall |
|---|---|---|---|---|---|---|---|---|---|---|
| base | 3 | 10 | 0 | 0 | **1** | 1 | 3846 / 2080 nets (iter 1) | 2522, then abort | — (died on `_167563_`) | 16:53 |
| jumper_only | 3 | 10 | 1 | 0 | **0** | **0** | 3846/2080 + 190/96 + 0 | 0 | **1209** | 49:37 |
| **diode_only** | 3 | 10 | 0 | 1 | **0** | **0** | 0 | **5241 + 2820 + 688 = 8749** | **522** | 22:55 |
| margin0 | 3 | 0 | 0 | 0 | **1** | 1 | 3129 / 1761 nets (iter 1) | — (died) | — (died) | 16:58 |

`margin0` is a clean negative: dropping the ratio margin changes the *first* iteration's count
(2643 against base's 2979) but the mixed pass still dies, so the margin is not the lever. Two
of the four variants clear the abort, and **`diode_only` is the better lever**: it leaves
522 violations against `jumper_only`'s 1209 and takes 22:55 against 49:37 — and it inserts the
diodes the step exists for (8,749, its own return value; `jumper_only`'s is 0 diodes). The
fatal no-path belongs to the *mixed* pass, which routes for jumpers first and then inserts
diodes: either restriction avoids it. Both still stop short of a repaired design — 522 and
1209 violations remain — but they get the flow past the abort.

Caveat on the row you pick: the flow-level arm already in flight (§4) was launched with
`-jumper_only`, the first variant to finish. `GRT_ANTENNA_REPAIR_DIODE_ONLY=true` is the
setting a fresh arm should carry.

Both passes are also *reproducible* rather than one-off: each variant is one OpenROAD process
on the flow's own input database, and the flow's own control (`base`) reproduced the flow's
exact sequence — 2979 violations, 3846 jumpers for 2080 nets, abort on `_167563_` — so the
table is the same instrument the flow runs.

The four settings are the entire lever surface LibreLane exposes for this call
(`GRT_ANTENNA_REPAIR_ITERS`, `_MARGIN`, `_JUMPER_ONLY`, `_DIODE_ONLY` — declared in
`steps/common_variables.py:412-441`, consumed by `scripts/openroad/antenna_repair.tcl`, which
passes them as `-iterations`, `-ratio_margin`, `-jumper_only`, `-diode_only`). There is no
other knob: the repair runs inside `OpenROAD.DiodeInsertion`, a subclass of the
global-routing step at `steps/openroad.py:1861` whose only script is `antenna_repair.tcl`
(`RepairAntennas.Steps = [_DiodeInsertion, CheckAntennas]`, `:1883`).

## 3. Arm B — the engine pin

### 3.1 Which build has the fixes

* The capacity half of `GRT-0183` is OpenROAD PR **#11093**, merged **2026-08-12**.
* The *fatal*-ness half is the recovery change: PR **#10711** was **closed, not merged**; the
  merged follow-up is PR **#11404**, commit `c751cdc`, merged **2026-09-14** (keeps the
  edge's original route and warns instead of aborting).
* First quarterly tag after both: **26Q4**, 2026-10-01. No *released* LibreLane carries
  either — the image here is pinned at `dcf36133` (2026-02-17), and LibreLane 3.0.16 and
  3.1.0.dev3 pin the same revision in `nix/openroad.nix`. **Updating LibreLane does not move
  OpenROAD.**

### 3.2 What it takes — three steps and two traps

1. **A binary.** `openroad/debian12:26Q4-407-geb14e40b7b` (2026-10-13) carries the 26Q4 line
   at `/OpenROAD/install/bin/openroad`; 1.13 GB compressed, ~5.6 GB on disk. (The
   `ubuntu22.04` sibling is 7.45 GB.) Extraction to 154 MB, recipe in
   `ws/tools/openroad_26q4.sh`'s header. **Trap 1:** the `tar -h` is load-bearing — without
   it the `.so` symlinks come out dangling and the only symptom is
   `libX11-xcb.so.1: cannot open shared object file`.
2. **A way in.** The flow runs in the nix image, whose loader cannot start a Debian-linked
   binary, so `ws/tools/openroad_26q4.sh` runs it under *its own* loader
   (`ld-linux-x86-64.so.2 --library-path ...`). LibreLane is pointed at that script with the
   hook it provides for exactly this: `_LLN_OVERRIDE_OPENROAD=/work/ws/tools/openroad_26q4.sh`
   (`OpenROADStep.get_openroad_path()`, `steps/openroad.py:297`; the ODB steps delegate to it
   at `steps/odb.py:59`, so every OpenROAD-backed step switches). **Trap 2:** with the pin
   wired in, the resume dies one step in, in `OpenROAD.GlobalRouting`, because this build
   bundles **Tcl 9** and the stdout channel comes up ASCII (Debian-linked binary, no locale
   data in the nix image):

   ```
   error writing "stdout": invalid or incomplete multibyte or wide character
       while executing "puts "Reading timing models for corner $corner_name…""
       (procedure "read_pnr_libs" line 17)
   ```

   `LC_ALL=C.UTF-8` does *not* fix it. The fix is `ws/tools/openroad_26q4_init.tcl`
   (`fconfigure stdout/stderr -encoding utf-8`), installed to `$HOME/.openroad` by the
   wrapper; OpenROAD sources that file unless `-no_init` is passed, and LibreLane does not
   pass it. `-no_init` restores the failure, which is how the fix was confirmed.
3. **LibreLane's own scripts, which is where it stops today.** With the encoding fixed, the
   whole GRT step runs on the new engine — 8 extra iterations, `Total wirelength:
   39,452,515 um`, no `GRT-0183`, against the pinned build's 39,459,512 µm — and then the
   step dies as it finishes:

   ```
   [ERROR STA-0107] _70aee23fd3100000_p_Scene is not the name of a scene.
   ... (procedure "sta::parse_scene_or_null" line 15) ...
   ```

   That is LibreLane 3.1.0.dev1's own `scripts/openroad/common/io.tcl` scene shim (its
   comment reads "*in OpenSTA 3, that's the scene's name again*") meeting an STA the shim
   does not know: OpenSTA commit `998806cb` (2026-06-30) made scenes pass as Tcl objects, and
   this image's LibreLane predates the fix — **LibreLane PR #1023**, merged 2026-09-06
   (`abbddfa`, "handle OpenSTA scenes bridged as objects in io.tcl"), shipped in **LibreLane
   3.0.13**, whose changelog reads "Added support for OpenSTA 3.1 in a backwards-compatible
   manner". The fix normalizes the two forms (`[sta::get_property $scene name]` when
   `sta::is_object`) instead of treating them interchangeably. So the engine pin needs **a
   flow whose LibreLane is at or past #1023** (≥ 3.0.13, or current `main`/`dev`); today's
   image is not, and LibreLane's own *OpenROAD* pin has not moved — `nix/openroad.nix` on
   `main` and `dev` still names `dcf36133`/2026-02-17 — so the 26Q4 binary stays
   self-supplied, which is what `_LLN_OVERRIDE_OPENROAD` is for. That is the real cost of
   this arm: not the swap (one variable + 154 MB), but the LibreLane version.
   [PR #1023](https://github.com/librelane/librelane/pull/1023) ·
   [OpenSTA 998806cb](https://github.com/The-OpenROAD-Project/OpenSTA/commit/998806cb) ·
   [main's openroad.nix](https://raw.githubusercontent.com/librelane/librelane/main/nix/openroad.nix)

### 3.3 The result on the failing step (the pin does fix the abort)

Same database, same command, same arguments, only the engine changed:

| engine | rc | GRT-0183 | sequence | wall |
|---|---|---|---|---|
| pinned `dcf36133` (2026-02-17) | **1** | 1 | 2979 → 3846 jumpers/2080 nets → 1299 left → 2522 diodes → **abort on _167563_** | 16:53 |
| 26Q4-407-geb14e40b7b | **0** | **0** | 2979 → 3718 jumpers/2072 nets → 483 left → 1642 jumpers → 114 left → 287 jumpers → 175 diodes → **complete** | 13:36 |

The new engine also repairs **better**: 114 violations left against 1299 at the point the
pinned build died. It wrote a database (`ws/probe/out_pin01/base/base.odb`, zstd'd) — the
first *diode-inserted* die database this project has had, which is what the earlier DRT
measurement had to go without (`RUN_ANTENNA_REPAIR=false`).

### 3.4 The #1023 backport — prepared, verified to apply, not yet run end-to-end

The blocker in §3.2/3 is a text problem, not a version problem: three procs in
`scripts/openroad/common/io.tcl`. The installed file (LibreLane 3.1.0.dev1, 760 lines) still
carries the 3.0.12 pre-image on all three, so #1023's own hunks apply verbatim.

* `ws/tools/librelane_1023_io_patch.py` applies exactly those edits: it checks every
  pre-image string first, writes nothing on a mismatch, verifies six post-conditions, and is
  idempotent (a second run reports `already-patched`). The pre-image match was itself read
  from the image, not assumed: `ws/tools/probe_librelane_io_tcl.py` (run in a throwaway
  container, `docker run --rm -v … -c '<nix python> /work/ws/tools/probe_librelane_io_tcl.py'`)
  printed the installed io.tcl (`writable=True`, 760 lines, no `scene_name`/`is_object`/
  `find_scene`, `set_cmd_scene` present) — the 3.0.12 shape #1023 patches.
* `ws/tools/librelane_1023_selftest.sh` runs it twice inside the flow image and prints the
  patched region. Measured in a throwaway container: `status=applied … edits=4 checks=6`,
  then `status=already-patched`, `SELFTEST rc=0`. `/nix/store` is writable in-container
  (docker's writable layer) and each new container starts from the unmodified image, so the
  patch is applied at container start and cannot drift; the host run tree is untouched.
* Wiring: `ws/die_predrt_exec.sh` runs it before `librelane` when `PREDRT_PATCH_LLN=1023` is
  set, and refuses the run if the patch did not apply — a silent fallback would look like an
  engine failure 30 minutes in.

What is NOT done: the end-to-end pinned resume. It needs the same ~9–13 GB the DRT arm is
using right now (§4.2), so the run to try is `build/die_drt_chain.sh` with
`PREDRT_OR=/work/ws/tools/openroad_26q4.sh` and `PREDRT_PATCH_LLN=1023`, once the die's DRT
step ends. Its first observable is the same GRT step finishing *without* `STA-0107`.

## 4. Arm A at flow level: the flow runs on to `OpenROAD.DetailedRouting`

`build/die_drt_chain.sh` with `DIE_PREDRT_OVERRIDE=GRT_ANTENNA_REPAIR_JUMPER_ONLY=true`,
`PREDRT_STOP=OpenROAD.DetailedRouting`, `DIE_PHASE_A_ONLY=1`, `PREDRT_MIN_GB=4` and
`DIE_ALLOW_CONCURRENT=1` (tag `diejmp01`) resumes the frozen step-36 state on the **pinned**
engine with the lever in place. The arm is read from the chain's log *and* from its own
`/proc/<pid>/environ`, so it is auditable rather than asserted: `PREDRT override=
GRT_ANTENNA_REPAIR_JUMPER_ONLY=true`, `PREDRT stop=OpenROAD.DetailedRouting`, `PREDRT
openroad_override=none`, and `resolved.json` carries the resolved knob
`"GRT_ANTENNA_REPAIR_JUMPER_ONLY": true` (`ITERS 3`, `MARGIN 10`).

| step | runtime | what its log says |
|---|---|---|
| `01-openroad-globalrouting` | 4:06 | `Global adjustment: 10%`, 8 extra iterations, wire 39,459,512 µm |
| `02-openroad-checkantennas` | 8:52 | pass |
| `03-odb-diodesonports` | 0.001 s | pass |
| `04-openroad-repairantennas` (1 `openroad-diodeinsertion`) | ~50 min | `repair_antennas … -jumper_only`: 2979 → 3846 jumpers/2080 nets → 1299 → 190 jumpers/96 nets → 1209, no diode pass, no `GRT-0183` — the flow's own copy of the probe's `jumper_only` row |
| `04-…` (2 `openroad-checkantennas`) | 03:12→ | the flow's own antenna check on the repaired database: **`ANT-0002` 1113 net violations, `ANT-0001` 1989 pin violations**, writing `antenna.rpt` + `antenna_summary.rpt` — and the step completes anyway |
| `05-openroad-stamidpnr-3` | 03:21→ | the last pre-DRT step (the chain's default stopping point), a pass-through on the database |
| `06-openroad-detailedrouting` | 03:40→ | the DRT step itself, with the landed `DRT_OPT_ITERS: 8`; **entered and running**, measured in §4.2. The flow's step order is the die02 reference run's, one number later because the repair is enabled here rather than skipped (`RUN_ANTENNA_REPAIR=false`) |

The `CheckAntennas` row is the one worth reading twice: the flow's own checker *does* count the
violations (`ANT-0001`/`ANT-0002`) and reports them to `antenna.rpt`, and the flow proceeds
anyway — so the estimate's tolerance for the 1209 the lever leaves is measured here rather
than inferred from the checkers' names.

What the DRT step will do, in the project's own documented terms (`wafer_space_integration/
grx930_overrides.yaml`, the `DRT_OPT_ITERS` block): `DetailedRouting` runs once, but its
`drt.tcl` loops — route, then `check_antennas`/`repair_antennas` and re-route while diodes are
actually inserted, up to `DRT_ANTENNA_REPAIR_ITERS` times (10 here), and **every pass gets a
fresh 8-iteration budget**; the loop exits as soon as antenna repair stops inserting diodes.
One pass is budgeted ~4 h (38 min initial route + 8 × ~26 min) from the measured core numbers,
and this is the assembled die rather than the bare core, so a first pass of a few hours before
the step's verdict is the expectation, not a stall — measured: 5:45:12 (§4.2).

Two launch facts are part of "what it takes": the first launch (02:07:35) was refused by the
chain's own disk gate — `DISK_GB_FREE 5` against the phase-A default floor of 12,
`ABORT_DISK_LOW` — and the arm was relaunched with `PREDRT_MIN_GB=4`; the memory preflight
passed (`headroom_mb=33350`, `need_mb=9000`, `verdict=OK`), and the run shares the box with
the antenna probe (`CONCURRENT_ALLOWED`, measured-light at ~2 GB RSS).

### 4.1 What the box needs — measured, and what had to be freed

* **Memory.** The die's DRT on the same pre-DRT database, 2 iterations, `-or_seed 42`, 8
  threads (`drt_fast/logs/die02_drt.log`): 23:25 per iteration, peak **8,123 MB**. The
  chains' memory gate carries 9,000–10,000 MB for exactly this. Measured since in the flow
  itself (§4.2): pass 0 peaked **9,065 MB**, pass 1 **12,255 MB** — so 9,000 MB covers the
  first pass only. A fresh DRT-bearing arm on this die should gate at ~13 GB; the box's
  15,613 MB total is the real limit, and it held (0 swap used, PSI 0).
* **Disk.** Both DRT-bearing chains gate at a **12 GB** floor, and at 02:07 the box had 4.1 GB
  free. The reclaim kept the project's rule — nothing in the run trees was touched — and took
  the two finished containers `ws_flow` (9 h old) and `drt_die02` (2 h old), 3.9 GB each (the
  per-container `/nix/store` the image's dev-shell materializes), plus the
  `openroad/debian12:26Q4` image (5.47 GB) once its extraction had been taken; the pin's
  `tools/or26q4` tree (307 MB) is what the wrapper runs, and the re-pull recipe stays in that
  wrapper's header. 4.1 GB → **17 GB free**.

### 4.2 The DRT step, measured (pass 0 complete; pass 1 in flight at writing time)

The step started **03:40:12 UTC** (its `_env.tcl`/`state_in.json`/`COMMANDS` mtimes) — this
is the answer to the request in one line: the die's flow is *in* detailed routing.

Pass 0 (`drt-run-0`), `-droute_end_iter 8`, the count being the router's own `DRT-0199` line:

| iteration | violations | wall |
|---|---|---|
| 0 (initial route) | 446,541 | 24:02 |
| 1 | 303,874 | 22:46 |
| 2 | 296,214 | 22:42 |
| 3 | 125,994 | 54:51 |
| 4 | 87,358 | 54:54 |
| 5 | 62,880 | 51:23 |
| 6 | 47,342 | 44:52 |
| 7 | 36,748 | 36:11 |
| 8 | **27,758** | 33:20 |

`[INFO DRT-0198] Complete detail routing.` — pass total **5:45:12**, peak **9,065 MB**. Two
readings matter against the project's own numbers:

* The per-iteration wall is **22–55 min**, not the core-only baseline's ~26 min: the die is
  bigger than the core the `DRT_OPT_ITERS` budget was measured on. The pass came in at
  5:45:12 against the block's ~4 h estimate. The cap is what stopped it, and the tail was
  still falling (33:20 for the last iteration) — the reading that instrument exists to
  classify.
* 27,758 is far below the only other die-side DRT datum (204,357, `drt_die02`, fast loop, 2
  iterations, composite-skipped database) — but the two are different arms: this one starts
  from the jumper-only database (1209 antenna violations unresolved), the fast loop from the
  composite-skipped one. Not a like-for-like improvement.

Then the step's own antenna stage runs, on the *routed* database (§4's loop):
`[INFO GRT-0012] Found 2428 antenna violations.` / `[INFO GRT-0015] Inserted 4013 diodes.` —
and because diodes were inserted, the step re-routes into `drt-run-1` with a fresh 8-iteration
budget.

Pass 1 (`drt-run-1`) so far:

| iteration | violations | wall |
|---|---|---|
| 0 (initial route) | 854,844 | 29:49 |
| 1 | 513,688 | 21:52 |
| 2 | 473,460 | 18:25 |
| 3 | 415,213 | (not yet flushed) |
| 4 (in flight) | 402,926 at 80 % | 1:51:54 so far |

Two readings: the re-route starts **1.9x worse** than pass 0's initial route (854,844 vs
446,541 — it routes around the 4013 diodes), and after three iterations it is still 15x above
pass 0's best. The antenna loop's passes are not refinements of each other — each is a fresh
route on a diode-laden database, and the loop's exit condition is "repair stops inserting
diodes", not "the count comes down". And pass 1 peaked at **12,255 MB** against pass 0's
9,065 (see §4.1).

State at writing time (~15:12 UTC): pass 1 iteration 4 running, ~7.2 cores busy (measured as
an utime delta on the router's pid), 12.5 GB RSS, 0 swap used, PSI 0 — computing, not wedged.
The late-iteration slowdown (1:20:31 at 60 %) is the same phenomenon the override file
documents from v8 (34 min early, 16–27 h later); the cap is what bounds it. One operational
caveat for anyone reading the run live: the step's own log is block-buffered and lags the
flow log by up to a buffer (the step log was 4 h behind at one point on 14 Oct) — read
`ws/logs/predrt_diejmp01.log` for the live tail.

Because a DRT verdict is hours away, the step is now watched by the project's own instrument:
`nohup ws/watch_drt_curve.sh --tag diejmp01` (with `WATCH_CONTAINER=die_predrt`), which wrote
its first reading to `ws/logs/drt_verdict.md`/`.txt` at 15:01 UTC — `CONVERGING tag=diejmp01
pass=1 best=473460 last=473460 n=3`, curving the pass in flight (pass 0's curve is the table
above). On exit it writes `drt_cap_cost.md` and, if the tail is still falling, hands the
pre-DRT database to `drt_extend_ws.sh` to measure the iterations the cap withheld — the
verdict lands in files whether or not anyone is watching.

### 4.3 What the diodes cost the router — the measurement §5 used to call impossible

`drt_fast/verdict/die_drt_at01.md` records its own limitation in its own words: "What the
missing diodes would have cost DRT is not measured — no diode-inserted die database exists —
so it is recorded as a limitation, not assumed small." That was true when it was written; it
is not true now. The antenna probe has since produced the databases (§2), and
`build/drt_db_compare_chain.sh` **routes them through the same fast loop, one arm per
database**, so that what differs between two curves is the database — eight threads,
`-or_seed 42`, Metal1–Metal5, three iterations each:

| arm | database | engine | why it is in the set |
|---|---|---|---|
| `jmp` | the flow arm's own DRT input, `runs/diejmp01/04-openroad-repairantennas/1-openroad-diodeinsertion/chip_top.odb` (1209 left, no diodes) | pinned | **the control**: the flow arm's probe twin `ws/probe/out/jumper_only/jumper_only.odb` is the same 246,613,739 bytes with the same md5 (`5f1d05ca…`), so if this loop is the router the flow's step ran, its first iterations must reproduce 446,541 / 303,874 / 296,214 |
| `pin26q4` | `ws/probe/out_pin01/base/base.odb` — 3,540 diodes + 5,647 jumpers, 114 left | 26Q4 `26Q4-407-geb14e40b7b`, the commit that wrote it, via `ws/tools/openroad_26q4.sh` | the question as asked: what does the **pin's** diode-repaired database route like |
| `pindiode` | `ws/probe/out/diode_only/diode_only.odb` — 8,749 diodes, no jumpers, 522 left | pinned | one variable against the control: diodes instead of jumpers, same engine, same base GRT database |
| `pinpinned` | the same file as `pin26q4` | pinned | splits the last confound: arm 1 vs 4 is the repair, arm 2 vs 4 is the build |

Three things were checked before it was launched, and they are why the comparison can be read
at all. The flow's own step log runs the same router the same way (`[INFO ORD-0030] Using 8
thread(s).`, `detailed_route -droute_end_iter 8 -or_seed 42 -verbose 1`; LibreLane states the
layer range with `set_routing_layers`, as `die_drt.tcl` does). Both engines answer — pinned
`dcf36133…`, 26Q4 `26Q4-407-geb14e40b7b`. And the chain refuses an arm unless the log that
produced its database names that exact file: `state_in.json` for the control, `ANT_PROBE_WROTE`
+ `ANT_DRIVER` for the probe databases. A fourth check came from the chain's own selftest,
`build/drt_db_compare_selftest.sh` (docker stubbed, no container and no router): it caught two
launch-path defects before any arm ran — a `local a=$1 … dblog=$a` that is an unbound variable
under `set -u`, and an engine cell built as `${OR:-a}${OR:+b}` that concatenated both branches.
Both would have fired on the first arm, hours in.

Launched 15:49:53 UTC and **waiting for the box** — its first line after the arm's hashes is
`WAIT_BEGIN jmp running='die_predrt'`. (A first instance went up at 15:38:55 and was stopped
before any arm ran, for the two defects the selftest found; no result was lost, because no
result existed yet.) The arms peak at 8.1 GB (measured, die02 fast loop) and
the flow step in flight holds 12.5 GB of a 15.6 GB box, so the chain waits for each arm rather
than contending and re-gates before each one. It does not preempt the watcher's own cap-cost
extension (`drt_extend_ws.sh`, queued at step end, 16 iterations, and pointed at this same
`jmp` database) — and that ordering was decided rather than raced, because both jobs wait
politely and either could take the box: the watcher was relaunched at 15:43 UTC with
`--no-extend` (its verdict capture unchanged, `VERDICT_FIRST CONVERGING`), so the four arms go
first and the extension is deferred, not cancelled. Results: `ws/logs/drt_db_compare.log`
and `drt_fast/verdict/die_drt_db_compare.md`, the report rewritten after **every** arm so a
partial run is still a result.

### 4.4 The flow itself, end to end, on a diode-repaired database (queued, behind §4.3)

§5's caveat — the die reached routing with **1209 antenna violations unresolved and no diodes at
all** — is a property of the *engine*, not of the design. The repair cannot complete on the
image's pinned OpenROAD (its global-router pass aborts on GRT-0183), so the only way the flow
in flight could get to step 06 was with the repair restricted to jumpers. The pin's own
measurement says the 26Q4 build completes that same repair on that same database: 2979 → 114
violations left, 3,540 diodes + 5,647 jumpers inserted (`ws/probe/out_pin01/base.log`).
`build/die_diode_flow_chain.sh` is that repair inside the flow, followed by the flow's own
step 06 on the database it produces — the arm that removes the caveat instead of qualifying it.

| | |
|---|---|
| resume state | `ws_v3/36-openroad-stamidpnr-2/state_out.json` — the same frozen state `diejmp01` and every probe consumed, so the database is the variable |
| steps | `OpenROAD.GlobalRouting` → antenna repair → `STA*` → `OpenROAD.DetailedRouting` (`PREDRT_STOP`) |
| engine | `ws/tools/openroad_26q4.sh`, OpenROAD `26Q4-407-geb14e40b7b` |
| backport | LibreLane #1023, applied in-container. **Required, and measured to be**: without it the pin arm dies as step 01 *finishes* — `[ERROR STA-0107] _70aee23fd3100000_p_Scene is not the name of a scene` (run `diepin02`, whose run tree stops at `01-openroad-globalrouting`) |
| repair config | the staged file, unmodified — no `GRT_ANTENNA_REPAIR_*` override, i.e. the flow as designed. `DIE_DIO_OVERRIDE='GRT_ANTENNA_REPAIR_DIODE_ONLY=true'` is the diode-only variant (8,749 diodes, 522 left), and §4.3's `pindiode` arm already routes that database |

Two consequences worth stating before the result exists. The arm runs the *unmodified* flow, so
its only difference from `diejmp01` is the engine — and the engine half is being isolated
separately by §4.3's `pin26q4` vs `pinpinned` arms, which route one database under both builds.
And if it stops before step 06, the report says so with the exact error rather than an empty
table: "is the #1023 backport sufficient end to end" is one of the things this arm tests.

Queued at 16:01:19 UTC, **behind §4.3** and behind the step in flight — its waiter logs
`WAIT_BEGIN running='die_predrt ' ahead='2000938 '`, where the hand-off to
`drt_db_compare_chain.sh` is explicit, because two "wait for an empty box" loops without it would
simply race for whichever moment the box empties first. Its harvester was validated *before* it
was queued, against the arm whose numbers are already published: run in `DIE_DIO_HARVEST=1` mode
against tag `diejmp01` it reproduces §4.2 exactly — pass 0 `446,541 → 27,758`, pass 1
`854,844 → 399,119` with `2,428 found → 4,013 diodes` before it, peak `12,254` MB. The first
version of that harvester read the `Completing 100% with` series instead of the router's
`DRT-0199` series and printed **421,043** for an initial route of 446,541; the test is the
reason that never reached a report.

Result path: `drt_fast/verdict/die_diode_flow_arm.md` (rewritten when the arm ends; it
currently holds the `HARVEST`-mode run against `diejmp01`, i.e. the jumper-only baseline in the
new report's format) and `ws/logs/die_diode_flow_chain.log`. The routed database and the
repaired one stay in `runs/died26q4/`.

## 5. What this does and does not establish

* Established: the fatal abort belongs to the pinned engine, not to the layout — a build
  containing #11093 + #11404 completes the identical call on the identical database and
  leaves fewer violations behind (114 against 1299 at the pinned build's death point); and on
  the pinned engine, either antenna-repair restriction alone gets the repair through
  (`-jumper_only`: 1209 left; `-diode_only`: 522 left, diodes inserted) — and the lever
  carries the flow itself to `OpenROAD.DetailedRouting` (§4). Also established: the pin's
  *mechanical* cost is small (one env var + 154 MB), and its  *practical* cost is not the
  swap but the LibreLane version: the flow-level blocker is LibreLane PR #1023, shipped in
  3.0.13 (§3.2/3) — and that blocker is now backported and verified to apply in-container
  (§3.4).
* Not established: the DRT verdict. The step is in flight and measured through pass 0 and
  part of pass 1 (§4.2); what remains is the verdict itself — whether any pass reaches 0,
  and how the antenna loop terminates — which `ws/logs/drt_verdict.md` (and `drt_cap_cost.md`
  at exit) now records automatically. Also open: whether the backported pin arm reaches DRT
  end-to-end (§3.4: verified as a patch, not yet as a run, and it needs the box's memory
  free); and whether `GRT_ADJUSTMENT 0.2` — the original reason the pin mattered — is the
  better value on a flow whose LibreLane is at #1023. Also open, and now being measured:
  §4.3's diode cost — four routed databases, launched and waiting for the box.
* Caveat that must travel with the lever: this flow arm reaches DRT with **1209 antenna
  violations unresolved** and no diodes (`-jumper_only`, §2), and the flow's own post-repair
  `CheckAntennas` measures the consequence on the database — 1989 pin / 1113 net violations
  (`ANT-0001`/`ANT-0002`) — and continues anyway. The design would carry those violations
  into signoff. `GRT_ANTENNA_REPAIR_DIODE_ONLY=true` is the better setting for a fresh arm
  (522 left, 8,749 diodes, 22:55) — and §4.3 is measuring the routing side of exactly that
  trade. Partial mitigation, measured: DRT's own antenna stage still ran on the routed
  database and inserted 4013 diodes (§4.2), so the DRT step repairs
  antenna violations even when the pre-DRT composite was restricted.
* LibreLane warns that self-supplied tool versions are unsupported and may be incompatible;
  §3.2's Trap 2 and §3.2's item 3 are two concrete instances, both named here rather than
  left as surprises.

## 6. Provenance

* Instruments: `ws/probe/antenna_probe.tcl`, `ws/probe/antenna_probe.sh`,
  `build/antenna_probe_chain.sh` (variants — now with a per-tag chain log; the two probe runs
  here shared one log until 02:05, so per-variant truth is in
  `ws/logs/antenna_probe.<tag>.container.log` and `ws/probe/out*/<variant>.log`),
  `ws/tools/openroad_26q4.sh` + `ws/tools/openroad_26q4_init.tcl` (the pin),
  `ws/tools/librelane_1023_io_patch.py` + `ws/tools/librelane_1023_selftest.sh` (the #1023
  backport and its in-container selftest), `wafer_space_integration/watch_drt_curve.sh` (the
  DRT step's own verdict instrument; run here as `--tag diejmp01`, `WATCH_CONTAINER=die_predrt`),
  `build/die_drt_chain.sh` + `ws/die_predrt_exec.sh` (`PREDRT_OR`, `PREDRT_PATCH_LLN`,
  `PREDRT_STOP`, `DIE_PHASE_A_ONLY`, `DIE_ALLOW_CONCURRENT`, and the `PREDRT_PATCH_LLN`
  forwarding that lets a chain ask for the #1023 backport at all),
  `build/die_diode_flow_chain.sh` + `DIE_DIO_*` (`TAG`, `OVERRIDE`, `STOP`, `WAIT`, `ATTEMPTS`,
  and the launch-nothing `PLAN=1` / `HARVEST=1` modes; the §4.4 arm), `build/drt_db_compare_chain.sh`
  + `ws/die_drt_exec.sh` (`DIE_DRT_OR`, `DRTDC_ARMS`/`_ITERS`/`_THREADS`/`_WAIT`/`_SELFTEST`;
  the four-database comparison of §4.3) and its selftest `build/drt_db_compare_selftest.sh`
  (docker stubbed, 25 checks, no container and no router — run it after touching either file).
* The arm results' destination: `build/stage_tapeout_config.sh` (+ `build/stage_tapeout_config_selftest.sh`,
  42 checks with docker and pgrep stubbed) writes the measured repair mode, and on the confirmed
  rung the engine pin and the #1023 backport, into the staged `grx930_overrides.yaml` and
  `ws/ws_exec.sh` as a delimited `MEASURED-STAGING` block — numbers, evidence md5s, rung and
  reason included — and `build/stage_tapeout_watch.sh`, live since 16:44 UTC, re-runs that job
  whenever the evidence moves (`build/stage_evidence.sh` defines the evidence set and its
  fingerprint once, for both scripts), so the block cannot go on describing a measurement that
  has since been superseded. It waits for an idle box rather than writing under an arm, which
  is the only safe order: the arms read that file at launch. See
  [tapeout_config_staging.md](tapeout_config_staging.md).
* Reconnaissance kept as evidence: `ws/probe/antenna_recon.sh` (what the image actually
  contains) and `ws/probe/antenna_recon2.sh` (which sub-step sets the flags).
* Logs: `ws/logs/antenna_probe_chain.log` (both probe runs, shared until 02:05),
  `ws/probe/out*/…`, `ws/logs/predrt_diepin02.log`, `ws/logs/predrt_diejmp01.log`,
  `ws/logs/die_drt_chain.log` (the `ABORT_DISK_LOW` at 02:07:35, the launch at 02:09:06, plus
the running chain's `/proc/<pid>/environ`), the DRT step's own
`runs/diejmp01/06-openroad-detailedrouting/openroad-detailedrouting.log` (the §4.2 curve),
`ws/logs/drt_verdict.md`/`.txt` + `ws/logs/drt_watch.log` (the watcher), and
`drt_fast/logs/die02_drt.log` (the die's
fast-loop DRT: 23:25 per iteration, peak 8,123 MB), `ws/logs/drt_db_compare.log` and
`drt_fast/verdict/die_drt_db_compare.{md,tsv,prov.txt}` + `drt_fast/logs/<arm>_drt.log`
(the §4.3 arms), and for §4.4: `ws/logs/die_diode_flow_chain.log`,
`drt_fast/verdict/die_diode_flow_arm.md`, `ws/logs/predrt_died26q4.{log,container.log}`,  `ws/logs/drt_watch_died26q4.nohup`; and for the staged configuration
  `ws/logs/stage_tapeout_config.log`, `drt_fast/verdict/tapeout_config_{staged.yaml,launcher.sh}.part`
  and the `.bak` of each file it edits.
* Housekeeping done for §4.1, recorded because it is part of what it took: `docker rm
  ws_flow drt_die02 ant_probe_pin01` and `docker rmi openroad/debian12:26Q4-407-geb14e40b7b`;
  `df` went 4.1 GB → 17 GB free. The run trees, the probe databases and the pin's
  `tools/or26q4` extraction were not touched; probe databases stay compressed (`zstd`) where
  permissions allow.
* Pin-pairing sources: LibreLane
  [PR #1023](https://github.com/librelane/librelane/pull/1023), merged 2026-09-06 (`abbddfa`),
  in the 3.0.13 changelog; OpenSTA
  [998806cb](https://github.com/The-OpenROAD-Project/OpenSTA/commit/998806cb) (2026-06-30);
  LibreLane `main`'s
  [`nix/openroad.nix`](https://raw.githubusercontent.com/librelane/librelane/main/nix/openroad.nix)
  (still `dcf36133`, 2026-02-17).
