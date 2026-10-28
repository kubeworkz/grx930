# arm64 vs x86 at GlobalRouting: the same route, and 5-vs-8 was the netlist

Written 2026-10-25 from two run trees: `ws_arm64_v1` on `ubuntu@2.31.100.64`
(aarch64, a fresh full flow from RTL) and `die01` on `ubuntu@49.13.6.8` (x86_64,
the resume of `ws_v3` at the landed `GRT_ADJUSTMENT` 0.1). It answers the question
the ARM box was provisioned to settle — does an arm64 build of the pre-check flow
route this die the way the x86 flow has routed it since October? — at the step
where the two differ, and at the step where they fail identically.

Extended 2026-10-26 with the replay this note asked for: `diea6401`, the die's own
frozen state — the same files `die01` resumed — run on the ARM box. It removes the
one variable the first comparison could not, the netlist, and it withdraws the
per-sweep-cost conclusion. Both are recorded below.

## Verdict

Global routing is equivalent, and on identical input it is *the same route*: fed
the die's own `ws_v3` database, the ARM box needs the same **8** overflow-removal
sweeps as x86, lands the same **39,459,512 µm** of wire and **1,656,170** vias,
reports the same resource and demand on every layer, and finishes with **0
overflow**, no `GRT-0115` and no `GRT-0183` (the replay `diea6401`, below).

The full-flow comparison that first asked the question put the arm64 route at **5**
sweeps with **3.25 % less wire and 1.94 % fewer vias** — on a netlist that differs
by 10 instances. The replay settles that: on the same database both architectures
agree to the unit, so the difference was the netlist, not the host.

One step later both runs **fail identically**: `OpenROAD.DiodeInsertion` aborts in
`repair_antennas`' own GRT pass with `[ERROR GRT-0183]`, on the same net
(`_167563_`), at the same call site, after the same 3,846 jumpers and 2,522 diodes.
So the ARM box neither fixes nor worsens the pre-DRT blocker, and an ARM arm is not
a way around the engine pin.

The claim this note has to withdraw is the per-sweep one. On equal work the ARM
box's sweep loop took **244 s against x86's 217 s**, so the earlier "arm64 7.8 %
faster per sweep" came from dividing unequal sweep counts. One run each on a shared
vCPU does not resolve host variance, and nothing here says either host routes
faster.

## The two runs

| | arm64 | x86 |
|---|---|---|
| host | `2.31.100.64`, Neoverse-N1 ×16, 30 GB | `49.13.6.8`, AMD EPYC-Rome ×8, 15 GB |
| image | `gf180mcu-precheck:arm64`, local build 2026-10-25 05:10 UTC, ID `sha256:494abbb8922a…` | `ghcr.io/wafer-space/gf180mcu-precheck:latest`, `f6c0cb88efce` |
| engine | `openroad dcf36133a369abc8f3c5e5738cd4d82e4903c0e0`, Yosys 0.66 `7f8fdfd8…` | same two builds |
| LibreLane | v3.1.0.dev1 | v3.1.0.dev1 |
| run tag / date | `ws_arm64_v1`, 2026-10-25 16:10 → 20:34 UTC | `die01`, 2026-10-13 |
| input database | own synthesis — full flow from RTL, GRT reads `35-resizertimingpostcts` via state 36 | `ws_v3/36-openroad-stamidpnr-2/state_out.json` (resume; same staged RTL, 38 sources) |
| knobs | 40 ns, `GRT_ADJUSTMENT` 0.1, `GRT_OVERFLOW_ITERS` 50, `GRT_LAYER_ADJUSTMENTS` `[0,0,0,0,0]` | identical, from the same `grx930_overrides.yaml` |

The two OpenROAD binaries are the same build, from the same commit, on both
architectures — that rules out an engine-version difference as an explanation
for anything below. `ws_chain.sh` hardcodes the `ghcr.io/…:latest` name, so the
local arm64 image is tagged with it; the first launch attempt on the box proves
no arm64 image exists upstream (`docker: no matching manifest for linux/arm64/v8
in the manifest list entries`, 16:08 UTC, before the retag).

## Step 37 — `OpenROAD.GlobalRouting`

| | arm64 | x86 | delta |
|---|---|---|---|
| extra iterations | **5 / 50** | **8 / 50** | −3 (−37.5 %) |
| final overflow, M1–M5 | 0/0/0/0/0 | 0/0/0/0/0 | — |
| `GRT-0115` finished with overflow | absent | absent | — |
| `GRT-0183` heap underflow | absent | absent | — |
| routed wirelength | 38,177,790 µm | 39,459,512 µm | −1,281,722 (−3.25 %) |
| routed nets | 243,798 | 243,780 | +18 |
| vias | 1,624,031 | 1,656,170 | −32,139 (−1.94 %) |
| 3D usage / demand | 8,719,794 · 3,847,701 (39.34 %) | 8,946,719 · 3,978,209 (40.65 %) | −2.54 % / −3.28 % |
| instances / cell area | 332,651 · 12,906,782.02 µm² | 332,661 · 12,903,897.53 µm² | −10 · +2,884 µm² (+0.022 %) |

### Why 5 sweeps and not 8

Not capacity. The die, core area, track pattern and PDN are the same, so the
derated resources are too — and the totals say exactly that: 9,779,909 against
9,786,451 is a 6,542 difference, which is precisely Metal1's (`766,568` vs
`773,110`, −0.85 %). Metal2–Metal5 are identical on both sides:

| layer | resource arm64 / x86 | demand arm64 / x86 | usage arm64 / x86 |
|---|---|---|---|
| Metal1 | 766,568 / 773,110 | 69,308 / 66,430 | 9.04 % / 8.59 % |
| Metal2 | 2,454,175 / 2,454,175 | 1,357,576 / 1,385,792 | 55.32 % / 56.47 % |
| Metal3 | 2,678,584 / 2,678,584 | 1,147,210 / 1,174,479 | 42.83 % / 43.85 % |
| Metal4 | 2,348,963 / 2,348,963 | 1,032,199 / 1,053,180 | 43.94 % / 44.84 % |
| Metal5 | 1,531,619 / 1,531,619 | 241,408 / 298,328 | 15.76 % / 19.48 % |
| **total** | **9,779,909 / 9,786,451** | **3,847,701 / 3,978,209** | **39.34 % / 40.65 %** |

The movement is all demand: the x86 database starts with 130,508 more units
(3.28 %), of which 133,386 are on Metal2–Metal5 (Metal1 is 2,878 lighter), so
x86 begins +1.31 pp of utilisation on the same vertical-layer budget and pushes
56,920 of that onto Metal5, the last-resort layer. Its route is correspondingly
longer (+3.25 % wire) and more via-heavy (+1.94 %). GRT's overflow-removal loop runs
until the congestion map is clean, and how many sweeps a cleaner start needs is
a function of that starting point — 5 against 8 is what a 3 % thinner route buys.
The engine does not print the running overflow total (`GRT-0102` is one line per
sweep, with no count), so the *initial* overflow is not recoverable on either
side; the sweep count is the only trajectory signal that exists, and it is used
here only as an ordinal.

The 10-instance difference shows up in exactly one resource: Metal1's, by
0.85 %. That is the layer whose charge is computed against the placed cells;
the die, core area, track pattern, macros and PDN that set Metal2–Metal5 are the
same in both databases, and those four resources match to the unit. The two
netlists are therefore not identical — 332,651 against 332,661 instances, with
+0.022 % area — which is the residual of mapping the same RTL with the same
Yosys/ABC build on a different target, and it is the one variable this
comparison cannot eliminate, since the arm64 arm is a full flow from RTL and the
x86 arm is a resume of an earlier x86 synthesis. It is 0.003 % of the instances
and it moves 4 % of Metal1's demand. That is not proof that this is the cause of
the 3 % demand gap, but it is why the result is an equivalence check at the
routing-step level rather than a bit-for-bit netlist A/B.

The replay below settles the question this section raises: on identical input the
ARM box also needs 8 sweeps, so 5-vs-8 describes a **netlist** difference, not an
architecture one.

### The per-iteration cost control

Wall clock alone would mislead: 155.4 s against 246.8 s looks like the ARM box is
substantially faster, and dividing each step by its own sweep count
(31.08 s against 30.85 s) looks like parity. Both are wrong, because each step
pays a fixed cost — reading the ODB, timing libraries, SDC, writing the result —
once, and dividing that by 5 instead of 8 understates the arm64 advantage:

| measure | arm64 | x86 | ratio |
|---|---|---|---|
| step wall (`runtime.txt`) | 155.421 s | 246.830 s | 0.63× |
| `GRT-0303` global routing runtime | 125 s | 217 s | 0.58× |
| step − `GRT-0303` (setup, I/O, metrics) | 30.4 s | 29.8 s | 1.02× |
| **average per extra sweep** | **25.0 s** | **27.1 s** | **arm64 7.8 % faster (this pair only — withdrawn below)** |

The fixed overhead is equal within 2 %, which is the control that makes the third
row usable: the only thing that differs per sweep is the sweep. Both runs are
single-threaded GRT (`threads` 1, average `cpu_percent` 99.83 / 99.84, peak RSS
3 GiB), so this is one core of EPYC-Rome against one core of Neoverse-N1, and
"7.8 % faster per sweep" is an average that folds in the initial route and via
filling (which `GRT-0303` includes and the sweep count does not divide), so treat
it as an upper bound on the sweep-cost difference, not a benchmark of the two
hosts. The point it establishes is narrow and sufficient: the 37 % wall gap is
5/8 of the work, not a host that is half the speed — for *this* pair of runs. On
equal work the comparison reverses (the replay's sweep loop is 244 s against x86's
217 s, below), so the 7.8 % here should not be read as an arm64 advantage.

## Step 40 — `OpenROAD.DiodeInsertion`: identical failure, +9 % more repairs

`CheckAntennas` (step 38) is also equivalent — 8:28.207 against 8:51.478 — and
then both runs die in antenna repair:

| | arm64 | x86 (die01) |
|---|---|---|
| jumpers inserted | 4,187 for 2,201 nets | 3,846 for 2,080 nets |
| diodes inserted | 2,688 | 2,522 |
| abort | `GRT-0183`, `antenna_repair.tcl` line 27 | same |
| net named | `i_chip_core.u_core.u_sram.mem[209][2]` | `_167563_` |
| diode-insertion runtime | 16:14.013 | 17:21.384 |

Same substep, same error code, same call site, different net — which is what a
deterministic no-path reached from two slightly different repair lists looks like.
The arm64 arm inserts 341 more jumpers and 166 more diodes before it hits the
wall, consistent with its netlist and its slightly different Metal1 demand, and
then stops exactly where x86 stops. Neither run reaches detailed routing, so this
note says nothing about an arm64 DRT verdict; that measurement still needs the
engine pin (OpenROAD ≥ the Aug 2026 GRT fixes, PR #10711 / #11093) or a repair
arm that avoids the failing pass.

Two harness observations from the same run, recorded because they affect how its
log reads. `ws_chain.sh` prints `WS_FLOW_EXIT rc=0` for this run although the flow
itself printed `WS_EXIT:2` and LibreLane quit with `[ERROR GRT-0183]` — judge such
a run by the flow log's exit line, not by the chain's. And the disk guard spent
the whole arm in `GUARD_WAIT … step_dir_absent`, because the step it was armed for
(`*-openroad-detailedrouting`) never appeared; with 238–246 GB free it never had
a reason to prune, so nothing was removed.

## The clean falsifier, run: the die's own database on the ARM box

`diea6401` (2026-10-26, 22:52 → 23:22 UTC, wall 30 min, container rc=2) is the
replay this note asked for. It is the x86 reference's own resume state —
`ws_v3/36-openroad-stamidpnr-2/state_out.json` and the 10 files it names, 722 MB,
md5-checked across the two boxes — run through `build/die_diode_flow_chain.sh` on
`ubuntu@2.31.100.64`. The engine is chosen in-container by
`ws/tools/openroad_engine.sh` → `ws/tools/openroad_arm64.sh` (the image's own
`dcf36133` under `stdbuf -oL`); the chain records it as `class=image`, because the
pinned 26Q4 build publishes amd64 only, and the arm's own log carries
`PREDRT openroad_override=/work/ws/tools/openroad_engine.sh dcf36133…`.

| measure | x86 `die01` | arm64 `diea6401` (replay) |
|---|---|---|
| input database | `ws_v3` step-36 state | **the same files, md5-identical** |
| extra iterations | 8 / 50 | **8 / 50** |
| final overflow, M1–M5 | 0/0/0/0/0 | **0/0/0/0/0** |
| `GRT-0115` / `GRT-0183` | absent | **absent** |
| routed wirelength | 39,459,512 µm | **39,459,512 µm** |
| vias | 1,656,170 | **1,656,170** |
| resource, M1…M5 (total) | 773,110 · 2,454,175 · 2,678,584 · 2,348,963 · 1,531,619 (9,786,451) | **identical, per layer** |
| demand, M1…M5 (total) | 66,430 · 1,385,792 · 1,174,479 · 1,053,180 · 298,328 (3,978,209, 40.65 %) | **identical, per layer** |
| instances / cell area | 332,661 · 12,903,897.53 µm² | **332,661 · 12,903,897.53 µm²** |
| step wall (`runtime.txt`) | 246.830 s | 274.061 s |
| `GRT-0303` routing runtime | 217 s | 244 s |
| step − `GRT-0303` (setup) | 29.8 s | 30.1 s |
| per sweep (`GRT-0303` / sweeps) | 27.1 s | 30.5 s |

Equality on the congestion table is the strong form of this check: the two hosts,
the same OpenROAD build, the same database and knobs, and every one of the five
layers' resource and demand identical — so the earlier "cleaner arm64 route" was
the arm64 netlist (+10 instances, +0.022 % cell area) and nothing else.

### And the same failure, to the net

| | x86 `die01` | arm64 `diea6401` |
|---|---|---|
| jumpers inserted | 3,846 for 2,080 nets | **3,846 for 2,080 nets** |
| diodes inserted | 2,522 | **2,522** |
| abort | `GRT-0183`, `antenna_repair.tcl` line 27 | **same** |
| net named | `_167563_` | **`_167563_`** |
| `CheckAntennas` wall | 8:51.478 | 8:26.654 (2,643 net + 4,323 pin violations) |

The replay's result is read from `ws/logs/predrt_diea6401.log`: the container's own
stdout is empty because `die_predrt_exec.sh` redirects the flow into that file,
which is also where the chain's report takes its quote from.

### What it does to the per-sweep claim

Equal work is the comparison this note could not make before, and it goes the
other way: 244 s for eight sweeps against x86's 217 s — 30.5 s against 27.1 s per
sweep, +12 %. The earlier 25.0 s/sweep was five sweeps on a lighter route, not a
faster host. So the 7.8 % in "The per-iteration cost control" is withdrawn as a
statement about the hosts; what survives is that the 37 % wall gap of the
full-flow pair is the sweep count.

## What this establishes, and what it does not

- **Establishes:** fed the same database, arm64 and x86 global routing produce
  the same route — same sweep count, wirelength, vias, per-layer resource and
  demand, zero overflow — and the pre-DRT path fails at the same place, on the
  same net, after the same insertions. The "cleaner" arm64 route in the
  full-flow comparison was the arm64 netlist (+10 instances, +0.022 % cell area)
  and nothing else. ARM is a usable substitute for the x86 flow box at this
  stage.
- **Does not establish:** that the two *netlists* are identical (they are not, by
  10 instances); that arm64 reaches DRT or closes it; that this reproduces on a
  second seed or a second ARM host; or any per-sweep cost advantage — on equal
  work the ARM box's sweep loop was 12 % slower, and one run each on a shared
  vCPU does not resolve host variance either way.
- **What would falsify it:** the same replay on a second ARM host, or the arm64
  netlist's state run on x86 (it now exists only on the ARM box, as
  `ws_arm64_v1/36-openroad-stamidpnr-2/state_out.json`). Neither is needed for
  the equivalence above; each would test it.

## Reproduction

```
# arm64 box; the local build is tagged with the name ws_chain.sh hardcodes
docker tag gf180mcu-precheck:arm64 ghcr.io/wafer-space/gf180mcu-precheck:latest
WS_TAG=ws_arm64_v1 nohup bash build/ws_chain.sh > ws/logs/ws_chain.arm64.nohup 2>&1 &
```

```
# x86 box; Phase A resumes ws_v3 at step 36 with the staged 0.1 config
DIE_TAG=die01 nohup bash build/die_drt_chain.sh > /dev/null 2>&1 &
# progress and the run's own banner (state path, engine, resolved knobs):
tail -f ws/logs/predrt_die01.log
```

```
# arm64 box; the replay — the die's own step-36 state and the 10 files it names
MEMWATCH_FORCE=1 DIE_DIO_TAG=diea6401 \
  nohup bash build/die_diode_flow_chain.sh > /dev/null 2>&1 &
# it records ARM_ENGINE ... class=image and writes
# drt_fast/verdict/die_diode_flow_arm.md
```

`MEMWATCH_FORCE=1` is not a tuning knob: this box has no swap and `memwatch`'s
preflight floor is `SwapFree 512 MB`, so every chain there refuses without it. The
override is recorded as `preflight FORCED` in `mem_audit/preflight.log`.

Numbers above come from, on each box,
`runs/<tag>/37-openroad-globalrouting/{openroad-globalrouting.log,runtime.txt,or_metrics_out.json}`
and `runs/<tag>/40-openroad-repairantennas/1-openroad-diodeinsertion/` — for `die01`
and `diea6401`, which are resume trees, those two steps are
`01-openroad-globalrouting` and `04-openroad-repairantennas/1-openroad-diodeinsertion`.
`resolved.json` in each run tree records the four knobs; the engine identities are
from `openroad -version` and `yosys -V` inside each image.
