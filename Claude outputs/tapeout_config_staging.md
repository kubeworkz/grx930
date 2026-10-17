# Staging the tapeout configuration from the measurements

`build/stage_tapeout_config.sh` (and its off-box test `build/stage_tapeout_config_selftest.sh`)
is the job that turns the antenna-repair arm results into the configuration the tapeout run
will actually launch with. `build/stage_tapeout_watch.sh` is what runs that job — it is **live**
as of 2026-10-14 16:44:57 UTC (pid 3614172, `ws/logs/stage_tapeout_watch.log`), re-staging
whenever the evidence moves and writing the missing block the moment the box empties. Its first
cycle shows the intended behaviour: `WATCH_CYCLE status=refused … reason='no MEASURED-STAGING
block in grx930_overrides.yaml -- job rc=1 (not recorded; retried next cycle)'`, with
`STAGE_BUSY running='die_predrt ' ahead='2000938 2334601 '` underneath — nothing written,
nothing recorded, and the arms' file untouched (both config sha256s verified unchanged).

Waiting is the only safe order: the arms read the very file the block is written into.

## 1. Why a job and not an edit

The staged overrides file (`ws/template/librelane/grx930_overrides.yaml`) leaves
`GRT_ANTENNA_REPAIR_*` at its default — the repair composite on and unrestricted — and its own
comment at line ~371 records what that does on the engine the pre-check image ships: the
repair's second invocation (`OpenROAD.DiodeInsertion` → `repair_antennas`) walks into
`[ERROR GRT-0183] Net _167563_: heap underflow during 3D maze routing`, which that build turns
into an abort. A tapeout run launched from the file as it stands cannot get past the repair
step. The modes that *can* finish have been measured (§2–§3 of
[die_to_drt_antenna_and_pin.md](die_to_drt_antenna_and_pin.md)); the missing piece was putting
one of them into the configuration, with the numbers next to it, at the moment the evidence
exists rather than from memory.

## 2. The three rungs, and what each needs

| rung | mode staged | evidence it must find | measured cost of the choice |
|---|---|---|---|
| **1** | unmodified repair (`DIODE_ONLY: false`, `JUMPER_ONLY: false`) **+ engine pin + #1023 backport** in `ws/ws_exec.sh` | the flow arm's own report must name tag `died26q4` **and** carry a pass-0 row, **and** its chain log must say `DIE_DIO_FLOW_COMPLETE tag=died26q4`, **and** a `DRT-0199` line must exist in that arm's logs | best outcome measured anywhere: **114** violations left, 3,540 diodes + 5,647 jumpers (`ws/probe/out_pin01/base.log`) |
| **2** | diode-only on the shipped engine (`DIODE_ONLY: true`, no pin) | `ws/probe/out/diode_only.log` with `rc=0` | **522** left, 8,749 diodes, 22:55 — completes without the pin or the backport |
| **3** | jumper-only (`JUMPER_ONLY: true`), block marked `SIGNOFF_COMPROMISE` | none — it is the floor | **1209** left, 0 diodes, 49:37; the arm in flight's own mode |

The rungs exist because the evidence arrives in an order nobody controls: the pin's 114 is the
best number and the only one that needs a *flow* run to confirm end to end, while the shipped
engine's 522 is already measured and needs no pin. Staging rung 1 on the strength of a probe
would be exactly the extrapolation this project refuses; staging rung 3 because the flow arm
has not finished yet would throw away the measured improvement. So the job reads the evidence
and takes the highest rung it can *back*, and it says which rung it took and why in the block
it writes.

## 3. What it writes (idempotent, delimited, backed up)

* `ws/template/librelane/grx930_overrides.yaml` — a `MEASURED-STAGING` block: the two knobs,
  the three measured repair outcomes, the fast-loop cost columns (or `not measured`), the
  engine/backport provenance on rung 1, and md5s of every evidence file the block quotes.
* `ws/ws_exec.sh` — a second `MEASURED-STAGING` block **on rung 1 only**: the engine pin
  (`_LLN_OVERRIDE_OPENROAD=/work/ws/tools/openroad_26q4.sh`) and the LibreLane #1023 backport,
  each with an escape hatch (`WS_OPENROAD=none`, `WS_PATCH_LLN=0`). On rungs 2/3 the block is
  *removed*, so a later rung cannot inherit a pin from an earlier one.
* `$F/…yaml.bak` beside each file, once, plus `drt_fast/verdict/tapeout_config_staged.yaml.part`
  (and `…_launcher.sh.part`) — the exact bytes written, extracted from the file rather than
  regenerated, so a host-side sync can mirror them without retyping.

The block as the real tree renders it today (rung 2, from `STAGE_CHECK=1`, which writes nothing):

```
# ==== BEGIN MEASURED-STAGING (generated 2026-10-14 16:22:56 UTC …) ====
# … Rung 2: rung 1 unconfirmed; the diode-only probe completed (rc=0). …
#   unmodified on the 26Q4 engine : 114 violations left, 3540 diodes + 5647 jumpers  (out_pin01/base.log, rc=0)
#   diode-only on the shipped engine: 522 violations left, 8749 diodes + 0 jumpers  (out/diode_only.log, rc=0)
#   jumper-only on the shipped engine: 1209 violations left, 0 diodes + 4036 jumpers  (out/jumper_only.log, rc=0)
#   jumper-only database     : not measured        <- §4.3's four arms, not yet run
#   The flow arm (unmodified repair, 26Q4 engine): NOT CONFIRMED -- it has not reached
#   DetailedRouting. The report on disk describes tag diejmp01. Quoted reason: …
#   The arm in flight, jumper-only, for reference: violations left 1209, DRT pass 0
#   446541 -> 399119, and the DRT step itself inserted 4013 diodes
GRT_ANTENNA_REPAIR_DIODE_ONLY: true
GRT_ANTENNA_REPAIR_JUMPER_ONLY: false
# ==== END MEASURED-STAGING ====
```

Both numbers are the arm logs' own (`ANT_PROBE_RESULT … rc=`, `[INFO GRT-0012] Found N antenna
violations.`, `[INFO GRT-0015] Inserted N diodes.`), summed or tailed as the probe wrote them;
the file's md5 is recorded under the block so a later reader can tell whether the block still
describes the files it names.

## 4. The mechanism, checked rather than assumed

`GRT_ANTENNA_REPAIR_JUMPER_ONLY` / `_DIODE_ONLY` are declared `Variable(..., bool, default=False)`
in `steps/common_variables.py:433-443` and reach OpenROAD through
`append_if_flag` (`scripts/openroad/common/io.tcl:706`) as `-jumper_only` / `-diode_only`. The
declaration makes them **mutually exclusive**, which is why the block sets exactly one true —
and why the truthiness is safe: Tcl's boolean parse accepts the `true`/`false` spelling YAML
produces, and the same file already carries `GRT_ALLOW_CONGESTION: true`.

This fence is narrow on purpose. The `OpenROAD.DetailedRouting` step runs its *own* antenna
repair from a **separate** pair (`DRT_ANTENNA_REPAIR_JUMPER_ONLY` / `_DIODE_ONLY`,
`steps/openroad.py:1968-1976`, `scripts/openroad/drt.tcl:107-108`) and the block leaves that
unrestricted: measured, it ran on the routed die and put **4,013 diodes** into it
([die_to_drt_antenna_and_pin.md](die_to_drt_antenna_and_pin.md) §4.2). Only the pre-DRT
composite is fenced, because only the pre-DRT composite is what aborts.

## 4b. Keeping it current: `build/stage_tapeout_watch.sh`

The measurements do not arrive at once — the pin's repair is a probe datum today, the flow
arm that confirms it end to end is queued behind two other chains, and the fast-loop cost
columns fill in one row per arm. A job that ran once would leave a block that was right when
written and wrong later: quoting `not measured` for an arm that has since run, or a rung-2
repair mode after the pin was confirmed. So the block is re-staged whenever the evidence
moves.

* **The trigger set is the evidence, defined once.** `build/stage_evidence.sh` lists the
  files the block quotes — `ws/probe/out*/*.log`, `drt_fast/verdict/die_drt_db_compare.tsv`,
  `drt_fast/verdict/die_diode_flow_arm.md`, `ws/logs/die_diode_flow_chain.log` — and hashes
  them into one fingerprint. Both scripts source it, so the watcher cannot watch a narrower
  set than the job reads (which would let a block go stale) or a wider one (which would fire
  on every router iteration; the multi-megabyte `predrt_*.log` is excluded for exactly that
  reason, and the block's reference line for an arm in flight is what refreshes on the next
  real trigger instead).
* **A change is confirmed before it is acted on.** The evidence must read the same twice, one
  cycle apart; a file being appended mid-write is refused as `status=unstable`. A *missing*
  block skips that: absence is unambiguous, and not acting would leave the tapeout config with
  no measurement in it.
* **It drives the job with `STAGE_WAIT=0`**, so "is the box free" stays the job's question.
  A refusal is `status=refused` and is **not recorded**, so the same change is retried on the
  next cycle — the one thing the watcher must never say is that this evidence has been
  handled when it has not.
* **Every re-stage is recorded**: `drt_fast/verdict/tapeout_config_stage.state` (fingerprint,
  when it was confirmed, the rung, a count) and `drt_fast/verdict/tapeout_config_stage_history.md`
  (a row per run: time, result, trigger, rung, fingerprint, block sha256). "Does the block
  describe the measurements on disk right now" is a question with a written answer.
* **Two locks, because there are two instances to keep apart.** The watcher holds
  `ws/logs/.stage_tapeout_watch.lock`; the job holds `ws/logs/.stage_tapeout_config.lock`
  around its decision and write, so a human running the job by hand while the watcher runs
  gets `STAGE_LOCK_HELD` instead of two interleaved writes. A stale lock (dead pid) is taken
  over loudly, not ignored.
* **Bounded, so it cannot go quiet on its own:** `STAGE_WATCH_HOURS=168` (7 days, `0` =
  forever) exits with `WATCH_DEADLINE`; the log gets a line per change of state and one an
  hour otherwise, so a stalled watcher is visible rather than merely silent.

## 5. What it refuses to do

* No probe evidence on disk (`ws/probe/out*/*.log`) → `STAGE_ABORT`, nothing written.
* Any `die_predrt`-style container, or `drt_db_compare_chain.sh` / `die_diode_flow_chain.sh`
  still alive → it waits (default), or refuses with `STAGE_BUSY` under `STAGE_WAIT=0`, because
  the queued flow arm reads this file at launch and editing it under an arm changes the arm.
* Nothing to back a number → the block says `not measured`, never a plausible value.
* Evidence that will not hold still → `STAGE_EVIDENCE_UNSTABLE` after four re-reads
  (`STAGE_MAX_RETRY`), writing nothing: a block that quotes numbers from two different states
  of the world is worse than no block. A single mid-run move is re-read and the run continues.
* More than one decider at a time → the second one refuses on the lock.
* A report naming another tag → not evidence. This is not theoretical: `die_diode_flow_arm.md`
  is rewritten for *every* arm and currently holds the jumper-only arm's harvest (`diejmp01`),
  whose pass-0 table row would otherwise pass a tag-blind rung-1 check.
* It never launches anything. The tapeout run stays a deliberate act.

## 6. Verification

* `bash build/stage_tapeout_config_selftest.sh` — **54 checks, 0 failures** (locally and on
  the box). It fixtures a fake tree with the real arm logs' line shapes and the measured
  numbers, and asserts all three rungs' blocks, the write path (one block per file, first line
  preserved, `.bak` kept, second run byte-identical, a later rung 2 removes a rung-1 pin), the
  block dumps, the lock (held → refuses; stale → taken over and released at exit), the
  evidence-moving cases (one move → `STAGE_EVIDENCE_CHANGED` then a write; a file that keeps
  moving → `STAGE_EVIDENCE_UNSTABLE`, nothing written), and both refusals (busy box, missing
  evidence).
* `bash build/stage_tapeout_watch_selftest.sh` — **44 checks, 0 failures** (locally and on the
  box), driving the watcher with a stubbed job: a missing block acts at once, a probe log that
  grows or a newly-appearing variant log re-stages, an unchanged tree stays quiet and leaves the
  config byte-identical, a moving file is refused and records nothing, a job refusal is retried
  rather than recorded, a job that leaves no block is an error rather than a success, a fresh
  watcher adopts an already-correct block, a second watcher refuses, a stale lock is taken over,
  and the deadline exits loudly.
* `STAGE_CHECK=1` against the **real** tree: decides rung 2, prints the block above, and leaves
  both files byte-identical (sha256 before/after equal).
* The CHECK runs caught two real defects before anything was written: a glob inside double
  quotes (`"$WS/…"/*/*.log` written as `"$WS/…/*/*.log"`) that silently made the jumper arm's
  count print `?`, and a sentence assembled after its own substitution that printed
  "NOT CONFIRMED … and it reached DRT with".

## 7. Limits

* The watcher re-stages on the next *evidence* change, so the block's reference line for an
  arm in flight can lag until then — that line is the one input deliberately left out of the
  trigger set (it is written per routing iteration).
* Rung 1's path is exercised only against fixtures so far. It becomes a measurement when
  `died26q4` runs — queued behind the DRT arm in flight and behind §4.3's four databases, so a
  day-scale wait on one 15.6 GB box — and only then can the job stage the pin and the backport.
* Until §4.3's arms run, the router-cost columns read `not measured`; the block is honest about
  that rather than quoting the bare-core fast loop as if it were the die.
* Rung 2 as it stands is a real cost, not a convenience: 522 unresolved antenna violations
  against the pin's 114. The block carries the `SIGNOFF_COMPROMISE` marker only on rung 3, so
  the distinction the rungs encode is visible in the file.
* The job writes the *staged* copy on the box. The repository's own
  `wafer_space_integration/grx930_overrides.yaml` is where a re-stage reads from, so that
  mirroring is a separate, deliberate step, and the `STAGE_NOTE`/dump paths exist to make it a
  copy.
* One consequence worth stating: after the block is written, a re-run of
  `build/die_diode_flow_chain.sh` no longer measures "the staged file, unmodified" — it measures
  the staged *mode*. The arm's `CONFIG_SHA256` line (from `die_drt_chain.sh`) is what tells the
  two apart, and `DIE_DIO_OVERRIDE` is how to pin a mode explicitly. The job logs that too.
