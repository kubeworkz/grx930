# Fresh baseline plan — RTL to routed DEF to a new-count ECO to GDS/SPEF

**Status: STAGE 8 CLOSED WITH RECORDED EXCEPTION — NOM SPEF EXTRACTED AND
VALIDATED; G0 READY_FOR_REVIEW, UNSIGNED.** The earlier stage records remain
below. The Stage 0 pin is `build/production/baseline/stage0/IDENTITY.md`. Stage 7
stream-out/ECO and Stage 8 nominal RCX have run; no min/max SPEF has been
produced. G2 remains blocked on G0 signoff, and the submission package remains
**VOID — DO NOT SUBMIT**.

This creates a **new identity**. It cannot claim `fix59`, `fix70`, the historical
541-row source, or the current 8,168-drop provenance. The existing submission
package stays **VOID — DO NOT SUBMIT** and G0/G2 stay blocked until this baseline
finishes, passes the gates below, and is signed.

## 1. Identity rule

A fresh baseline is production-eligible only when one pinned set of netlist, PDK,
flow config, DEF, GDS, and SPEF hashes is used from synthesis through signoff.
Changing any of them creates a new baseline and invalidates every prior G0/G2
result.

## 1.1 Determination: the fresh baseline needs a new ECO count

**The 8,168-drop geometry cannot be reproduced by a fresh RTL-to-P&R run.** It is
a property of the old fix16/fix70 database:

- **7,626 `sub` island drops** come from the connected M1 components of the `sub`
  net in the fix16 GDS. A new placement and route changes that connectivity.
- **540 row drops (of 541)** come from VSS labels and VSS/VDD M3 strips in the old
  GDS, with row 300 excluded because its only clean M2 route overlapped VDD. A new
  PDN and placement changes the row set and the row-300 congestion.
- **2 `$45264` rail drops** are tied to one auto-generated net name from the old
  synthesis. A fresh synthesis will not preserve `$45264`; the equivalent rail
  connection must be re-identified, and the count may differ.

Only reusing the exact old routed database preserves 8,168, and that is not a
fresh baseline (and the database is absent). Therefore this plan derives a new
drop list with a new count `N = N_sub + N_rows + N_rail`. G0, the DEF/GDS check,
and the fixtures must take `N` as a parameter; the 8,168 fixtures remain
historical/synthetic controls only. If the project requires exactly 8,168, the
path is to recover the old database, not to run this plan.

## 1.2 Production host and checkout path

The production target verified on 2026-11-18 is:

- **Host:** `ubuntu@2.31.100.64` (`ubuntu-32gb-fsn1-1`, aarch64; 31,260 MiB
  total memory).
- **Source checkout:** `/home/ubuntu/grx930` (git branch
  `npu/shim-tile-model`; it has a local LVS commit, so Stage 2 uses a clean
  `/home/ubuntu/grx930_stage2` worktree at `6278466` rather than resetting it).
- **Flow root:** `/mnt/HC_Volume_107515356/grx930_ol2`; this is the deployed
  tree mounted at `/work`, not a git checkout. It contains `ws/`, `build/`, and
  `openlane2_rtl/`.
- **Flow image:** `gf180mcu-precheck:arm64`, the local aarch64 build of the
  pinned pre-check image.

The old assumption `ubuntu@49.13.6.8:/home/ubuntu/grx930_ol2` is retired. The x86
host does not have that path; it has only an old `/home/ubuntu/grx930` checkout,
and its root filesystem has 36 GiB free (its auxiliary volume has 4.3 GiB).

No host may start Stage 2 until the readiness gate in the Stage 2 section writes
`status=PASS` for `/mnt/HC_Volume_107515356/grx930_ol2` with
`disk.available_gb >= 150`. That gate now records **197 GiB free and
`status=PASS`**. Stage 2 was launched on 2026-11-18.

## 2. Existing assets to reuse

| Purpose | Path | Notes |
|---|---|---|
| Full-chip flow runner | `c930/asic_gf180mcu/ws/ws_exec.sh` | LibreLane Chip flow; `WS_TAG`, `WS_LIMIT`, `WS_FROM`, `WS_OVERRIDE`; `cd /work/ws/template`; runs land in `librelane/runs/<tag>/` |
| Template source | `c930/asic_gf180mcu/tools/gf180mcu-project-template/` | `librelane/` and `src/`; untracked local checkout, not in target `6278466`; transfer it to the clean worktree before staging; contains its own `.git` |
| Slot config | `.../librelane/slots/slot_1x1.yaml` | pad ring and DIE/CORE area; **3932 × 5122 µm**, core `[442, 442, 3490, 4680]` |
| Design overrides | `c930/asic_gf180mcu/wafer_space_integration/grx930_overrides.yaml` | SHA-256 `2e35833d4adc80560f81dce9a13f0f5b1f437e134e8a0c095b2f16c46a3910c9`; GRT 0.1, DRT_OPT_ITERS 8, antenna 10/10 |
| Core adapter | `.../wafer_space_integration/chip_core_grx930.sv` | SHA-256 `585661ccc48cf1852ac0d9829abced93bac1beb3f151dbe640ad0f55d8b91c0b`; replaces `src/chip_core.sv` |
| PDN config | `.../wafer_space_integration/pdn_cfg_grx930.tcl` | SHA-256 `cb9fd56896f184fd435f133b3bef370d8825f2ebf97a1ed880da5bbb1e29f00b`; destination is `librelane/pdn/` |
| Macro list | `.../wafer_space_integration/macros_grx930.yaml` | destination is `librelane/macros/`; 5 declarations, 0 demo SRAM |
| RTL tree | `c930/asic_gf180mcu/openlane2_rtl/src/` | destination is `ws/template/asic_core/`; 40 `.sv`; exclude `c930_bootrom.sv` and `bootrom_wrapper.sv` |
| Pre-DRT resume | `c930/asic_gf180mcu/ws/die_predrt_exec.sh` | records the exact resume shape and state-file contract; a fresh run starts from RTL |
| Fast DRT loop | `c930/asic_gf180mcu/drt_fast/{run_drt.sh,die_drt.tcl,drt_fast.tcl}` | `run_drt.sh` hardcodes `D=/work/drt_fast`; output is `$FAST_OUT/$FAST_TAG.odb` |
| DRT chain + guard | `c930/asic_gf180mcu/build/{die_drt_chain.sh,drt_curve_guard.sh,drt_db_compare_chain.sh,gate.sh}` | budgets, divergence kill, disk/memory gate |
| Fill / stream / stitch / CDL | `c930/asic_gf180mcu/tools/lvs_chip/{fill_def.py,stream_out.py,pdn_stitch.py,mk_chip_cdl.py}` | the actual GDS construction; must run in the OpenLane image |
| Stream/route checks | `.../tools/lvs_chip/{stream_check.py,net_compare.py}` | layer/placement and DEF-vs-CDL checks |
| Cell/tech LEF | `c930/asic_gf180mcu/build/cells.lef` | 5 routing layers and 56 `VIA` definitions; the only via-geometry source for `stream_out.py` |
| PDK cell GDS | `c930/asic_gf180mcu/build/lvs_chip/pdk_fd_sc_mcu7t5v0.gds` | `stream_out.py` and `pdn_stitch.py` read cell layouts from it |
| G0/G2 | `build/production/run/{g0_freeze.sh,g2_lvs.sh,gds_checks.rb,def_gds_checks.rb}` | die, count, paths, and the row-300 box are hardcoded |

**Toolchain status:** the production ARM flow box has
`gf180mcu-precheck:arm64` at the pinned pre-check identity. Stage 1 pulled and
verified the in-image CIEL `792ef…` PDK, OpenROAD `dcf3613…`, and RCX rules.
The retired x86 image reference is not the production flow target. The local
`openlane2-gf180mcu:latest` and `ghcr.io/efabless/openlane2:2.3.10` images are
not the full-chip flow image.

**Why the GDS pipeline matters.** The production GDS is not a single stream-out.
`fill_def.py` adds fillers and well taps, `stream_out.py` renders the filled DEF,
and `pdn_stitch.py` adds the M2 straps that join the M1 rails to the M3 grid. The
fix16 base is exactly that chain (`..._stream_out_filled_stitched_fix16.gds`), and
the `sub` islands this plan must find exist only after the fill and stitch passes.
`stream_out.py` now builds its `VIA_<name>` cells from the LEF `VIA` definitions
the DEF names and refuses a via with no definition, so the VOID artifact is no
longer in the fresh-baseline GDS path.

## 3. Stages

### Stage 0 — Freeze the identity and choose the floorplan

Inputs: RTL tree, overrides, slot config, PDK version, flow image, `cells.lef`
(including its 56 `VIA` definitions), and the PDK cell GDS.

Record before any compute:
- Netlist entry: full-chip `openlane2_rtl` RTL through `ws_exec.sh`, 40 files,
  tree SHA-256 `7c4d919b1950033089a2a43b8be729defb9ff50e2a50873865552b76f85049b9`.
  The old Yosys netlist and audit DEF are **not** inputs. The flow's `DESIGN_NAME`
  is `chip_top`, so the routed ODB and netlist top is `chip_top`; `stream_out.py`
  names the GDS top `grx930_test_chip`. The CDL must be written with
  `grx930_test_chip` as its top, or G2's `topcell` will name a netlist the deck
  does not have (Stage 4).
- Die/core: the ws `slot_1x1` template, the audit DEF, and G0 all use
  **3932 × 5122 µm** (core `[442, 442, 3490, 4680]`). The old 3930 × 5120 figure
  is retired and must not be used. A fresh floorplan uses the template die; G0
  already defaults to 3932 × 5122.
- **ECO count:** new count `N`; do not plan for 8,168 (see §1.1).
- Corner/RCX set: `nom`, `min`, `max` from the PDK RCX rules.

Output: `build/production/baseline/baseline_manifest.sha256`,
`stage0/IDENTITY.md`, and `stage0/netlist_sha256.txt`. The manifest pins the RTL
tree, overrides, PDN, macros, PDK version, flow image index digest, die/core,
LEF, cell GDS, and `N=TO_BE_DERIVED`; the netlist manifest pins the 40 RTL files
plus `chip_top.sv`, `chip_core_grx930.sv`, and `slot_defines.svh`. Stage 0 has
replaced the `TO_BE_PINNED` placeholders.

Gate met: every input has a hash and there is exactly one netlist/floorplan pair
(`identity=FROZEN_REPINNED`). Stage 1 has pulled the image, verified its PDK
(`792ef…`), OpenROAD (`dcf3613…`), and RCX files, and recorded the pad-ring/mask
comparison; see `baseline/stage1/STAGE1_VERIFICATION.md` and
`baseline/stage1/PAD_RING_MASK_COMPARISON.md`. The 792 cell LEF/GDS and merged
`cells.lef` have replaced the old 0fe pins. The flow has not started.

### Stage 1 — Toolchain and PDK readiness

**Result 2026-11-18: PASS — PDK/RCX re-pin PASS; production host readiness
passes on the volume-backed flow root.** The pinned image was pulled and inspected read-only. Stage 0 was
moved to its CIEL/Open_PDKs `792ef…` PDK and OpenROAD `dcf3613…`; the RCX rules
are present at `gf180mcuD/libs.tech/librelane/`. The 0fe→792 pad-ring/mask
comparison found the GDS pad-opening layer identical and requires no pad-ring or
floorplan edit. Full records: `baseline/stage1/STAGE1_VERIFICATION.md`,
`baseline/stage1/STAGE1_READINESS.txt`, and
`baseline/stage1/PAD_RING_MASK_COMPARISON.md`.

- Pull and pin the full-chip image by index digest, not a tag:
  `docker pull --platform linux/amd64 ghcr.io/wafer-space/gf180mcu-precheck@sha256:104d…`
  and record `docker image inspect --format '{{.Id}}'`.
- Inspect its PDK at the default `--pdk-root /workspace/gf180mcu`; resolve
  `gf180mcuD` and verify the OpenRCX rules at
  `gf180mcuD/libs.tech/librelane/rules.openrcx.gf180mcuD.{nom,min,max}`. If the
  image's PDK or OpenROAD does not match the frozen pin, stop; Stage 8 cannot
  run.
- Pin `ghcr.io/efabless/openlane2:2.3.10` (fill/stream/stitch/CDL) and
  `grx930/klayout-lvs-pmap:local` (G2 deck).
- Run the explicit host gate on the production host, against
  `/mnt/HC_Volume_107515356/grx930_ol2`:

  ```bash
  /home/ubuntu/grx930/c930/asic_gf180mcu/build/stage1_readiness.sh \
    --volume /mnt/HC_Volume_107515356/grx930_ol2 \
    --record /mnt/HC_Volume_107515356/grx930_ol2/build/production/baseline/stage1/STAGE1_READINESS.txt
  ```

  The script is present in the source checkout. It requires at least 12 GiB
  available memory for pre-DRT, 8 GiB for a DRT arm, and 150 GiB free on the
  volume. The production run records 29,179 MiB available (both memory floors
  PASS) and 197 GiB free (`disk=PASS`), with `status=PASS`. The flow-chain
  `gate.sh` remains the per-arm launch guard, not a substitute for this Stage 1
  record.

Output: `toolchain_versions.txt`, `STAGE1_READINESS.txt`, and
`STAGE1_VERIFICATION.md` (librelane, OpenROAD, KLayout, image digests, PDK path,
RCX hashes, host readiness, pad-ring/mask comparison, and the pass verdict).

Gate: the exact RCX rule files and OpenROAD build are readable **and match the
frozen pin**, and `STAGE1_READINESS.txt` has `status=PASS`. A version bump or a
resource-gate failure restarts the Stage 1 check. The current production record
is **PASS** (197 GiB free volume), so this gate is **MET**. Stage 2 was launched
on 2026-11-18.

### Stage 2 — RTL through global route to a pre-DRT ODB

**Prerequisite — passing production readiness gate.** Do not run any command in
this section until the gate above writes a record ending `status=PASS` and
`disk.available_gb >= 150` for `/mnt/HC_Volume_107515356/grx930_ol2`. The
production volume now records 197 GiB free and `status=PASS`. The owner
authorized Stage 2 on 2026-11-18; it was launched after the checks below, and its
acceptance gate remains pending.

The container mount root is the deployed flow root
`/mnt/HC_Volume_107515356/grx930_ol2`, **not the source checkout and not the
repository root**: `ws_exec.sh` does `cd /work/ws/template`, and the RTL tree is
at `/work/openlane2_rtl`.

**Production source preflight — use a clean target worktree.** The existing
source checkout is at `f1ae96f`, one local LVS commit on top of `82dea44`.
The pushed target `6278466` also descends from `82dea44` but does not contain
`f1ae96f`, so a `git pull --ff-only` cannot work. Do not reset the existing
checkout or discard its local commit. Preserve it on a branch and check out the
exact flown commit in a separate worktree.

On the production host the checkout's `origin` is
`git@github.com:kubeworkz/grx930.git`, but the host has no GitHub SSH key, so
`git fetch origin` fails with `Permission denied (publickey)`. Do not rewrite
`origin`; fetch the same published ref over HTTPS into the remote-tracking ref:

```bash
set -e
OLD_SRC=/home/ubuntu/grx930
SRC=/home/ubuntu/grx930_stage2
ROOT=/mnt/HC_Volume_107515356/grx930_ol2
TARGET=62784668c1e95f74933aa73dcd5935f0ce67e136

test -z "$(git -C "$OLD_SRC" status --porcelain --untracked-files=no)"
# SSH origin has no key on this host; fetch HTTPS without changing the remote.
GIT_TERMINAL_PROMPT=0 git -C "$OLD_SRC" fetch https://github.com/kubeworkz/grx930.git \
  +npu/shim-tile-model:refs/remotes/origin/npu/shim-tile-model
test "$(git -C "$OLD_SRC" rev-parse origin/npu/shim-tile-model)" = "$TARGET"
test "$(git -C "$OLD_SRC" rev-parse FETCH_HEAD)" = "$TARGET"
git -C "$OLD_SRC" branch -f prod/pre-sync-f1ae96f f1ae96f9e152d91263bb34693be0b6f60b50ab1a
test ! -e "$SRC"
git -C "$OLD_SRC" worktree add --detach "$SRC" "$TARGET"
test "$(git -C "$SRC" rev-parse HEAD)" = "$TARGET"
test -x "$SRC/c930/asic_gf180mcu/build/stage1_readiness.sh"
```

Rerun the readiness gate from that exact worktree before staging. The record is
written to the flow volume, and every floor must be `PASS`:

```bash
bash "$SRC/c930/asic_gf180mcu/build/stage1_readiness.sh" \
  --volume "$ROOT" \
  --record "$ROOT/build/production/baseline/stage1/STAGE1_READINESS.txt"
grep -qx 'mem.pre_drt=PASS' "$ROOT/build/production/baseline/stage1/STAGE1_READINESS.txt"
grep -qx 'mem.drt_arm=PASS' "$ROOT/build/production/baseline/stage1/STAGE1_READINESS.txt"
grep -qx 'disk=PASS' "$ROOT/build/production/baseline/stage1/STAGE1_READINESS.txt"
grep -qx 'status=PASS' "$ROOT/build/production/baseline/stage1/STAGE1_READINESS.txt"
```

**The clean target worktree does not contain the template source.** Commit
`6278466` does not track
`c930/asic_gf180mcu/tools/gf180mcu-project-template` (`git ls-tree HEAD` is
empty and there is no submodule entry). The local repository has the pristine
template as an untracked checkout at the same path, at commit
`6876569f06bd66bec83e9a3856d9524d1bb33eac`. The first production staging attempt
on 2026-11-18 stopped at the missing `librelane/config.yaml` precondition, before
any backup or swap; the live tree and its 13 runs were untouched.

Transfer that checkout into the worktree without its `.git`, then verify the
files the flow depends on:

```bash
TPL=c930/asic_gf180mcu/tools/gf180mcu-project-template
TAR=/tmp/gf180mcu-template.tgz
tar --exclude=.git -czf "$TAR" -C "$(dirname "$TPL")" "$(basename "$TPL")"
scp "$TAR" ubuntu@2.31.100.64:/home/ubuntu/gf180mcu-template.tgz
ssh ubuntu@2.31.100.64 '
  SRC=/home/ubuntu/grx930_stage2
  DEST="$SRC/c930/asic_gf180mcu/tools/gf180mcu-project-template"
  test ! -e "$DEST"
  tar -xzf /home/ubuntu/gf180mcu-template.tgz \
    -C "$SRC/c930/asic_gf180mcu/tools"
  test -f "$DEST/librelane/config.yaml"
  sha256sum "$DEST/librelane/config.yaml" \
            "$DEST/librelane/slots/slot_1x1.yaml" \
            "$DEST/src/chip_top.sv"
'
```

The 2026-11-18 transfer was 97 KiB / 52 files and produced these hashes:

```
53873a3e040dc30e939a4be9e8b6d06abbcedafa82cd5fcdcbcebbe5ddfc85ba  librelane/config.yaml
cb47d6bb0e23d802c7b1fd54307880be466a3e6a09622222d47d73601a26b5a9  librelane/slots/slot_1x1.yaml
fe6019f5e105d83fbe2979796fa55e2620c11ef159c12982f5fdb01a863f43e5  src/chip_top.sv
```

The transferred directory is intentionally untracked; the source worktree's
`HEAD` remains `6278466`. If the worktree is recreated, repeat this transfer
before running the staging block.

Stage the template transactionally. The existing tree has old run trees under
`ws/template/librelane/runs` (13 at the time of this plan). The block below
inventories every run by name and content, moves the **entire** existing
`ws/template` to `ws/.template.backup.<UTC>.<pid>/template` before the swap
(nothing is deleted), stages and validates the replacement beside it, moves the
run trees into the new template, and re-inventories every one. A name, file-hash,
directory, or symlink difference restores the old template and exits non-zero.

```bash
# stage2-staging-block-begin
set -euo pipefail

SRC=${SRC:-/home/ubuntu/grx930_stage2}
ROOT=${ROOT:-/mnt/HC_Volume_107515356/grx930_ol2}
EXPECT_RUNS=${EXPECT_RUNS:-13}
RECORD=${RECORD:-$ROOT/build/production/baseline/stage2/STAGING_RECORD.txt}
FLOW="$SRC/c930/asic_gf180mcu"
WS="$ROOT/ws"
LIVE="$WS/template"
RUNS="$LIVE/librelane/runs"

# Preconditions. Nothing below this point may run against a different tree.
for f in \
    "$FLOW/tools/gf180mcu-project-template/librelane/config.yaml" \
    "$FLOW/wafer_space_integration/grx930_overrides.yaml" \
    "$FLOW/wafer_space_integration/macros_grx930.yaml" \
    "$FLOW/wafer_space_integration/pdn_cfg_grx930.tcl" \
    "$FLOW/wafer_space_integration/chip_core_grx930.sv" \
    "$FLOW/wafer_space_integration/fill/fill_active.rb" \
    "$FLOW/openlane2_rtl/src/grx930_test_chip.sv"
do
    test -f "$f"
done
test -d "$LIVE"
test -d "$RUNS"
test ! -L "$RUNS"
test -f "$LIVE/librelane/config.yaml"
# Bind staging to the flown tree, not the old checkout with its local LVS commit.
TARGET=62784668c1e95f74933aa73dcd5935f0ce67e136
test "$(git -C "$SRC" rev-parse HEAD)" = "$TARGET"

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
BACKUP="$WS/.template.backup.$STAMP.$$"
test ! -e "$BACKUP"
mkdir "$BACKUP"

# One inventory line per run: sha256 of its sorted file-hash manifest, its name,
# file count and byte count. The per-run manifests also record every directory
# and every symlink target, so the after-comparison checks layout as well as
# bytes. Hashing reads run data; it writes only the manifests in the backup.
snapshot_runs() {  # snapshot_runs RUNS_DIR OUT_DIR
    local runs=$1 out=$2 name dir digest files bytes
    mkdir -p "$out"
    find "$runs" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | LC_ALL=C sort > "$out/names.txt"
    : > "$out/digests.txt"
    while IFS= read -r name; do
        dir="$runs/$name"
        ( cd "$dir" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum ) \
            > "$out/$name.files.sha256"
        ( cd "$dir" && find . -type d -printf '%P\n' | LC_ALL=C sort ) \
            > "$out/$name.dirs.txt"
        ( cd "$dir" && find . -type l -printf '%P -> %l\n' | LC_ALL=C sort ) \
            > "$out/$name.links.txt"
        digest=$(sha256sum "$out/$name.files.sha256" | cut -d' ' -f1)
        files=$(awk 'END { print NR }' "$out/$name.files.sha256")
        bytes=$( cd "$dir" && find . -type f -printf '%s\n' | awk '{ s += $1 } END { printf "%d", s + 0 }' )
        printf '%s  %s  files=%s bytes=%s\n' "$digest" "$name" "$files" "$bytes" \
            >> "$out/digests.txt"
    done < "$out/names.txt"
    [ "$(awk 'END { print NR }' "$out/names.txt")" -eq "$EXPECT_RUNS" ]
}

compare_runs() {  # compare_runs BEFORE AFTER
    local before=$1 after=$2 name kind
    cmp -s "$before/names.txt" "$after/names.txt" || {
        echo "stage2: run names differ" >&2
        diff -u "$before/names.txt" "$after/names.txt" | head -40 >&2 || true
        return 1
    }
    cmp -s "$before/digests.txt" "$after/digests.txt" || {
        echo "stage2: run content digests differ" >&2
        diff -u "$before/digests.txt" "$after/digests.txt" | head -40 >&2 || true
        return 1
    }
    while IFS= read -r name; do
        for kind in files.sha256 dirs.txt links.txt; do
            if ! cmp -s "$before/$name.$kind" "$after/$name.$kind"; then
                echo "stage2: run $name $kind differs" >&2
                return 1
            fi
        done
    done < "$before/names.txt"
}

MOVED_OLD=0
SWAPPED=0
STAGE=
rollback() {
    local rc=$?
    trap - EXIT
    if [ "$rc" -eq 0 ]; then exit 0; fi
    echo "stage2: staging failed (rc=$rc); restoring the old template" >&2
    if [ "$SWAPPED" -eq 1 ]; then
        if [ -d "$LIVE/librelane/runs" ] && [ ! -e "$BACKUP/template/librelane/runs" ]; then
            mv "$LIVE/librelane/runs" "$BACKUP/template/librelane/runs" \
                || echo "stage2: could not return runs to the backup" >&2
        fi
        if [ -d "$BACKUP/template" ]; then
            # SWAPPED=1 means $LIVE is the new tree; the old one is in the backup.
            rm -rf "$LIVE"
            mv "$BACKUP/template" "$LIVE" || echo "stage2: ROLLBACK MOVE FAILED" >&2
        fi
    elif [ "$MOVED_OLD" -eq 1 ] && [ ! -e "$LIVE" ] && [ -d "$BACKUP/template" ]; then
        mv "$BACKUP/template" "$LIVE" || echo "stage2: ROLLBACK MOVE FAILED" >&2
    fi
    if [ -n "$STAGE" ] && [ -d "$STAGE" ]; then rm -rf "$STAGE"; fi
    exit "$rc"
}
trap rollback EXIT

snapshot_runs "$RUNS" "$BACKUP/runs-before"

# Build the replacement beside the live tree; nothing has been touched yet.
STAGE=$(mktemp -d "$WS/.template.stage.XXXXXX")
cp -a "$FLOW/tools/gf180mcu-project-template/." "$STAGE/"
rm -rf "$STAGE/.git"
cp "$FLOW/wafer_space_integration/grx930_overrides.yaml" "$STAGE/librelane/"
cp "$FLOW/wafer_space_integration/macros_grx930.yaml" "$STAGE/librelane/macros/"
cp "$FLOW/wafer_space_integration/pdn_cfg_grx930.tcl" "$STAGE/librelane/pdn/"
cp "$FLOW/wafer_space_integration/chip_core_grx930.sv" "$STAGE/src/chip_core.sv"

# KLAYOUT_FILLER_SCRIPT points at ../fill/fill_active.rb; the template does not
# contain that deck, so stage the wafer-space fill files explicitly.
mkdir -p "$STAGE/fill"
cp -a "$FLOW/wafer_space_integration/fill/." "$STAGE/fill/"

# Copy the whole RTL tree, not just *.sv: any .svh, relative include, or
# subdirectory the core needs must survive. Exclude only the two unused ROM
# modules named in grx930_overrides.yaml.
mkdir -p "$STAGE/asic_core"
cp -a "$FLOW/openlane2_rtl/src/." "$STAGE/asic_core/"
rm -f "$STAGE/asic_core/c930_bootrom.sv" "$STAGE/asic_core/bootrom_wrapper.sv"

# Fail before replacing a good tree if the staged tree is incomplete.
test -f "$STAGE/src/chip_top.sv"
test -f "$STAGE/src/chip_core.sv"
test -f "$STAGE/src/slot_defines.svh"
test -f "$STAGE/asic_core/grx930_test_chip.sv"
test ! -e "$STAGE/asic_core/c930_bootrom.sv"
test ! -e "$STAGE/asic_core/bootrom_wrapper.sv"
test -f "$STAGE/librelane/slots/slot_1x1.yaml"
test -f "$STAGE/librelane/config.yaml"
test -f "$STAGE/librelane/grx930_overrides.yaml"
test -f "$STAGE/librelane/macros/macros_grx930.yaml"
test -f "$STAGE/librelane/pdn/pdn_cfg_grx930.tcl"
test -f "$STAGE/fill/fill_active.rb"
test ! -e "$STAGE/librelane/runs"
[ "$(find "$STAGE/asic_core" -maxdepth 1 -type f -name '*.sv' | awk 'END { print NR }')" -eq 38 ]
[ "$(grep -c '^  gf180mcu' "$STAGE/librelane/macros/macros_grx930.yaml")" -eq 5 ]

# The swap: the entire old template is renamed into the backup, never deleted.
mv "$LIVE" "$BACKUP/template"
MOVED_OLD=1
mv "$STAGE" "$LIVE"
SWAPPED=1
STAGE=

# The run trees are moved (not copied) so the volume does not need a second
# copy of days of run data. Their before manifests stay in the backup.
mv "$BACKUP/template/librelane/runs" "$LIVE/librelane/runs"

snapshot_runs "$LIVE/librelane/runs" "$BACKUP/runs-after"
compare_runs "$BACKUP/runs-before" "$BACKUP/runs-after"

mkdir -p "$(dirname "$RECORD")"
{
    echo "stage2_template_staging=PASS"
    echo "when_utc=$STAMP"
    echo "source_worktree=$SRC"
    echo "source_commit=$(git -C "$SRC" rev-parse HEAD 2>/dev/null || echo unknown)"
    echo "flow_root=$ROOT"
    echo "backup=$BACKUP"
    echo "runs=$EXPECT_RUNS"
    echo "runs_verified=name+content"
    echo "backup_runs_relocated_to=$LIVE/librelane/runs"
    echo "status=PASS"
    echo "# per-run content digest, name, files, bytes"
    cat "$BACKUP/runs-before/digests.txt"
} > "$BACKUP/STAGING_RECORD.txt"
cp "$BACKUP/STAGING_RECORD.txt" "$RECORD"

trap - EXIT
echo "stage2: staged $LIVE"
echo "stage2: backup $BACKUP"
echo "stage2: $EXPECT_RUNS run trees verified by name and content"
echo "stage2: record $RECORD"
# stage2-staging-block-end
```

The before inventory is `$BACKUP/runs-before/`: `names.txt`, `digests.txt`, and
per run `<run>.files.sha256`, `<run>.dirs.txt`, `<run>.links.txt`; `runs-after/`
is the same inventory taken from the new location. A `digests.txt` line carries
the SHA-256 of the run's sorted file-hash manifest, the run name, file count and
byte count, so `compare_runs` proves each old tree survived under the same name
with the same bytes, directories and symlink targets. A missing, renamed,
truncated or changed run fails the compare and triggers the rollback above; a
count alone is never accepted.

The backup holds the entire old template at the instant of the swap. The run
trees are then moved into the verified new tree rather than copied, because a
second copy of days of run data could drop the volume below the 150 GiB floor;
their before manifests stay in the backup. Keep the backup and its
`STAGING_RECORD.txt` until the Stage 2 gate is accepted. Both inventories read
every run file, so budget one full read of the run tree before the swap and one
after, plus the manifest space in the backup.

The block was rehearsed locally on 2026-11-18 with
`bash build/production/stage2_staging_simulation.sh`: 49/49 checks, 13 synthetic
run trees preserved and byte-compared, the backup held the old template, and a
missing-source failure left the live tree and its runs untouched. `EXPECT_RUNS=13`
is only a guard against a changed set; the per-run name+content comparison is the
verification. The production run on 2026-11-18 then performed the fetch, target worktree, gate
rerun, staging swap and flow launch; its staging record is
`build/production/baseline/stage2/STAGING_RECORD.txt`. This simulation remains
the disposable rehearsal.

`grx930_overrides.yaml` declares `VERILOG_FILES` as `../src/chip_top.sv`,
`../src/chip_core.sv`, and `../asic_core/*.sv`; `PDN_CFG` is
`dir::pdn/pdn_cfg_grx930.tcl`, which is why the PDN file goes under
`librelane/pdn/`. `ws_exec.sh` writes `src/generated_defines.svh` itself.

The tag must not exist yet. Check both the run directory and container namespace
before launching (both are expected to be empty):

```bash
test ! -e "$ROOT/ws/template/librelane/runs/prod_stage2_01"
test -z "$(docker ps -a --filter name=prod_stage2_01 --format '{{.Names}}')"
docker image inspect gf180mcu-precheck:arm64 \
  --format '{{.Architecture}} {{.Id}}' | grep '^arm64 '

ROOT_NEED_GIB=${ROOT_NEED_GIB:-10}
ROOT_FREE_GIB=$(df -BG / | awk 'NR==2 {sub(/G$/,"",$4); printf "%d\n", $4}')
test "${ROOT_FREE_GIB:-0}" -ge "$ROOT_NEED_GIB"
echo "root_free_gib=$ROOT_FREE_GIB (need >= $ROOT_NEED_GIB)"
```

`/` also holds `/var/lib/docker` and the git worktree metadata; the flow-volume
gate does not cover it. The 2026-11-18 launch was made with only 1.6 GiB free
and later required reclaiming 17.4 GiB while the run was live. A launch must
stop at this check and reclaim space if it fails. If
`docker info --format '{{.DockerRootDir}}'` is outside `/`, apply the same check
to that filesystem.

Run on the production host with a fresh tag. This is the launch command; do not
run it until the owner says go and the root check passes:

```bash
docker run --rm --user 0:0 \
  -v /mnt/HC_Volume_107515356/grx930_ol2:/work \
  -e WS_TAG=prod_stage2_01 \
  -e WS_LIMIT=OpenROAD.STAMidPNR-3 \
  gf180mcu-precheck:arm64 /work/ws/ws_exec.sh
```

`WS_TAG` must be fresh; resuming an old tag reuses its netlist. `STAMidPNR-3` is
the last pre-DRT state: the STA steps pass the ODB through, and the DRT step reads
the ODB named by the last `state_out.json`. At 0.1 the antenna step can abort with
`GRT-0183`; `ws_exec.sh` installs `lln_antenna_catch.sh`, which keeps the inserted
diodes and lets the step write its database. Treat that as a recorded condition,
not a silent pass, and archive the antenna log.

Output: the staged template, its `ws/.template.backup.*` and
`build/production/baseline/stage2/STAGING_RECORD.txt`; then the ODB named by the
newest `ws/template/librelane/runs/prod_stage2_01/*/state_out.json`; copy it to
`build/production/baseline/pre_drt.odb` and keep the state file.

Gate (run these before accepting the ODB):

```bash
RUN="$ROOT/ws/template/librelane/runs/prod_stage2_01"
test -f "$RUN/resolved.json"
grep -Fq '"GRT_ADJUSTMENT": 0.1' "$RUN/resolved.json"
grep -Fq '"DRT_OPT_ITERS": 8' "$RUN/resolved.json"
test "$(grep -ahoE 'Global adjustment: [0-9]+%' "$RUN"/*openroad-globalrouting/*.log | tail -1)" = 'Global adjustment: 10%'
! grep -Rqa 'GRT-0183' "$RUN"

PDN=$(find "$RUN" -maxdepth 1 -type d -name '*-openroad-generatepdn')
test "$(printf '%s\n' "$PDN" | sed '/^$/d' | wc -l)" -eq 1
test "$(grep -c 'PDN-0001.*Inserting grid' "$PDN"/*.log)" -eq 1

MC=$(find "$RUN" -maxdepth 1 -type d -name '*-openroad-checkmacroinstances' | head -1)
test -n "$MC"
test -f "$MC/state_out.json"
! grep -Rqa 'No macro instance' "$MC"

LAST=$(find "$RUN" -maxdepth 2 -name state_out.json -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2-)
ODB=$(sed -n 's/.*"odb": "\([^"]*\)".*/\1/p' "$LAST" | head -1)
ODB_HOST="$ROOT/${ODB#/work/}"
test -f "$ODB_HOST"
mkdir -p "$ROOT/build/production/baseline"
cp -f "$ODB_HOST" "$ROOT/build/production/baseline/pre_drt.odb"
```

`resolved.json` shows `GRT_ADJUSTMENT: 0.1` and `DRT_OPT_ITERS: 8`; the GRT log
contains `Global adjustment: 10%`. No `GRT-0183` may appear in any step log — a
caught occurrence is a failure under this gate; archive the log and stop rather
than accepting the ODB. PDN must be inserted exactly once and the macro-instance
check must pass. Cell count and die must match the frozen manifest.

**Timing provenance — ss/ff are `STA_PREPNR`, not pre-DRT signoff.**
`final/metrics.json` carries one key per corner, but only the default
`nom_tt_025C_5v00` corner is re-measured after `STA pre-PnR`: every mid-PnR STA
step (`30`, `34`, `36`, `41`) runs that corner alone. The
`nom_ss_125C_4v50` and `nom_ff_n40C_5v50` entries are inherited unchanged from
step 12 (`12-openroad-staprepnr`), measured on the synthesized netlist with an
ideal clock before placement, CTS, resizing and global routing. They are **not**
measurements of the pre-DRT ODB and must not be read as a Stage 2 gate result.
In the 2026-11-18 run the inherited ss entry was `wns -139.20 ns`,
`tns -786532.5`, `setup_vio 30348` and ff was `wns -30.69 ns`, `tns -32747.4`,
`setup_vio 3383`, while the only corner measured on the pre-DRT database was
`nom_tt_025C_5v00` at `wns 0`, `ws +1.56 ns`. The ss value came from unbuffered
high-fanout nets in the synthesized netlist (`_349120_/Q` →
`u_rom.line_p1[2]` at fanout 2142 and a 270 ns slew, `_380465_/Q` →
`o_pipe_out[0]`, `_380850_/Q` → `o_pipe_out[15]` at 1316, `rst_n_PAD` →
`i_chip_core.rst_n` at 4266), which the resizer later rewrote; the pre-DRT
netlist buffers `line_p1[2]` to roughly 30 loads. Re-measure ss and ff on the ODB
named by `41-openroad-stamidpnr-3/state_out.json` before accepting Stage 3.

### Stage 3 — Complete detailed routing

Precondition — measured and **met** on
`build/production/baseline/stage2/ss_setup_fix/pass4/pre_drt_sssetup4.odb`
(sha256 `dc2d325b…c0eb0`), the ODB Stage 3 seeds from (`FAST_ODB` below points
at it). Both corners were re-measured on 2026-11-19 with global-route parasitics
asserted inside the STA process (guarded `corner.tcl`, `grt::have_routes`): ss
setup **+0.050768 ns** with **0 endpoints**, ff setup **+7.775756 ns**, ff hold
**+0.101570 ns**, both clean.

**Database chain.** `build/production/baseline/pre_drt.odb`
(sha256 `c76785bf…54dc`) → ss-targeted resize (`stage2/ss_closure/`, 12 buffers,
220 resizes) → `pre_drt_ss.odb` (`1bcba3a9…e7d11`) → one ff hold buffer
(`stage2/ff_hold_fix/`) → `pre_drt_ffhold.odb` (`c44b2ec6…047f5`) → ss-targeted
repair, pass 4 (`stage2/ss_setup_fix/pass4/`) → **`pre_drt_sssetup4.odb`**
(`dc2d325b…c0eb0`), the launch database. The pre-repair corner measurements on
`pre_drt_ffhold.odb` and on the unrepaired `pre_drt.odb` are retained in
`stage2/sta_odb_ffhold/` and `stage2/sta_odb/`; the guarded pass-4 result below
supersedes both.

**ss setup repair.** `stage2/ss_setup_fix/` ran the flow's resizer sequence
targeted at `nom_ss_125C_4v50`: refresh the global routes, `estimate_parasitics
-global_routing`, one `repair_timing -setup`, detailed placement, then global
route again. Each GRT run is followed by a hard `grt::have_routes` assertion, so
no pass optimized on placement parasitics. The saved database is pass 4 (100
resizes, no new buffers); passes 1–3 and one discarded run that repaired at the
wrong corner are retained in the same directory and marked superseded, not used.

**Guarded two-corner STA — `pre_drt_sssetup4.odb`.** `stage2/sta_odb_sssetup/`
runs `corner_guarded.tcl`, the flow `corner.tcl` plus one inserted block that
aborts with an error when `[grt::have_routes]` is false; the exact delta is
`corner_guarded.diff`, and both `sta.log`s print `global_routes_asserted=true`.
One process per corner, the same `chip_top.sdc` (sha256 `0885ff0e…d2e6`),
propagated clock, OpenROAD `dcf36133…`:

- `nom_ss_125C_4v50`: setup **passes** — `WNS 0`, `TNS 0`, worst slack
  **`+0.050768 ns`**, **0 violating endpoints**; hold **passes** at
  `+1.421780 ns` with 0 endpoints.
- `nom_ff_n40C_5v50`: setup **passes** at **`+7.775756 ns`** with 0 endpoints;
  hold **passes** at **`+0.101570 ns`** with 0 endpoints.

Reports, `or_metrics_out.json` and `SUMMARY.txt` are archived in
`build/production/baseline/stage2/sta_odb_sssetup/`, and the result is recorded
in `build/production/baseline/stage2/EXIT_REPORT.txt`.

**Model caution — the withdrawn +0.012 ns claim.** The 2026-11-19 00:14 STA on
`pre_drt_ss.odb` (archived in `stage2/sta_odb_ssfix/`) reported ss `+0.012 ns`
only because the resizer had invalidated that ODB's global routes and
`sta/corner.tcl` silently substituted `estimate_parasitics -placement`. That
figure is a placement-parasitics artifact, never signoff. Any corner measured on
a database that has been through placement must assert `grt::have_routes` (as
`corner_guarded.tcl` now does) rather than trust that fallback.

So the `STA_PREPNR` re-measure step is **satisfied** and the Stage 3 precondition
is **met** on `pre_drt_sssetup4.odb`. Two margins are thin and must be watched:
ss setup has 50.8 ps and ff hold 101.6 ps, neither through RCX or crosstalk yet.
Slew, fanout and cap violations are untouched (89,292 / 3,085 / 3,898 at ss).
Launch Stage 3 on `pre_drt_sssetup4.odb`, never on `pre_drt.odb`,
`pre_drt_ss.odb` or `pre_drt_ffhold.odb`, and only with explicit approval.

Stage `c930/asic_gf180mcu/drt_fast` at `/work/drt_fast` in the image; the runner
hardcodes `D=/work/drt_fast` and its default `FAST_OPENROAD` is a build-machine
Nix path. Set `FAST_OPENROAD` to the OpenROAD binary inside the precheck image.

```bash
docker run --rm --user 0:0 \
  -v /mnt/HC_Volume_107515356/grx930_ol2:/work \
  -e FAST_TAG=prod01_drt \
  -e FAST_ODB=/work/build/production/baseline/stage2/ss_setup_fix/pass4/pre_drt_sssetup4.odb \
  -e FAST_END_ITER=2 -e FAST_THREADS=8 \
  -e FAST_MIN_LAYER=Metal1 -e FAST_MAX_LAYER=Metal5 \
  -e FAST_TCL=/work/drt_fast/die_drt.tcl \
  -e FAST_OPENROAD=openroad \
  gf180mcu-precheck:arm64 bash /work/drt_fast/run_drt.sh
```

`FAST_OPENROAD=openroad` resolves through the image entrypoint's nix-shell
`PATH`; the script's own default is a build-machine store path that does not
exist here. Run `docker run --rm \
gf180mcu-precheck:arm64 sh -lc 'command -v openroad'` first if the name is not
found.

The container command must be `bash /work/drt_fast/run_drt.sh`, not the bare
script path: `run_drt.sh` starts with `#!/bin/bash`, the image has no
`/bin/bash`, and Docker then fails before the script runs with
`.../run_drt.sh: bad interpreter: No such file or directory` (rc 126). `bash`
resolves only through the entrypoint's nix-shell `PATH`. The first probe launch
on 2026-11-19 failed exactly that way; prefixing `bash` fixed it.

**Probe result — 2026-11-19, tag `prod01_drt`, `FAST_END_ITER=2`.** The probe ran
with `drt_curve_guard.sh` attached and exited rc=0 on a decreasing curve:
iteration 0 **398,816** violations, iteration 1 **255,218**, iteration 2
**246,191**. It ran 04:52–05:48Z. Output
`drt_fast/out/prod01_drt/prod01_drt.odb` (387,500,774 B, sha256
`dbd06e3e595bc416c418eb43312384573254c12cf80ddbea5f9a352b124680be`); the router
log and `.drc` sit beside it, the command is `stage3/PROBE_CMD.txt`, and the
curve, ODB hash and input hash are in `stage3/probe/`. The guard recorded no
stop. **Gate: FAIL** — 246,191 violations remain, so the probe is not a routed
production baseline and Stage 3 cannot exit on it. The last iteration removed
only 3.7%, so the 8-iteration pass is expected to lower the count without
reaching 0; unless it does, Stage 3 requires a numbered, owner-signed waiver
naming the residual count and categories.

**Full-pass result — 2026-11-19, tag `prod01_drt8`, `FAST_END_ITER=8`.** Seeded
from the same pre-DRT ODB and run under the same guard. It started 05:49:29Z and
exited rc=0 at 08:36:56Z (2 h 47 m). Violations by iteration: 398,816 → 255,218 →
246,191 → **67,819 → 31,754 → 16,800 → 8,826 → 5,416 → 3,805**. The guard
recorded no stop and retired only when the container was gone. Output
`drt_fast/out/prod01_drt8/prod01_drt8.odb` (393,195,240 B, sha256
`1bd7e7e23991f6484f42300535323489187cb76a0148cc4d07294f15d593ff07`), with
`prod01_drt8.drc` beside it (11,415 lines). Peak memory was 8.9 GB. **Gate at
that point: FAIL** — 3,805 violations remained and none were waived; it was
superseded by the continuation below.

**Continuation result — 2026-11-19, tag `prod01_drt16`, `FAST_END_ITER=16`,
seeded from `prod01_drt8.odb`.** The launcher
`build/production/baseline/stage3/launch_pass.sh` was extended with an optional
third argument so the arm reads the prior database instead of the Stage 2
pre-DRT ODB; the exact invocation is `stage3/ARM16_CMD.txt`. The arm ran
17:40:37Z–18:44:44Z (1 h 04 m) and exited rc=0. Violations by iteration:
3,831 (0th) → 3,829 → 3,831 → 3,004 → 2,550 → 2,046 → 1,642 → 1,426 → 1,267 →
786 → 109 → 23 → 10 → 9 → 9 → 9 → **0**; the router stopped at iteration 11
because the route was clean, so the 16-iteration budget was not exhausted. The
six counts from 23 onward are internal passes of iteration 11. The guard recorded
`CURVE_CLEAN pass=1 iter=11 count=0` and no stop (`STALL_ITERS=0` was used so the
plateau rule could not end the asymptote measurement; regression and wall-clock
bounds stayed armed). Output `drt_fast/out/prod01_drt16/prod01_drt16.odb`
(392,900,136 B, sha256
`a433816bded175fec8a66090478399c447fcee2fc686ab79c0d89e3a9a40d07e`) with a
**0-byte** `prod01_drt16.drc`; a read-back in the flow image reported 337,060
instances and 244,238 nets. **Gate: MET — 0 DRT violations.** The database was
copied byte-identically to `build/production/baseline/routed.odb` (same sha256).

Run the same with `FAST_END_ITER=8` and a **new tag** (`prod01_drt8`) only after
the probe shows a decreasing violation curve; `die_drt.tcl` writes
`$FAST_OUT/$FAST_TAG.odb`, so reusing the probe tag would overwrite the probe.
Keep `drt_curve_guard.sh` attached to kill a divergent pass and to bound
per-iteration and per-pass wall time. Do not use the last ODB if the curve
diverged; the guard exists because the router writes the last database, not the
best one.

Output: `/work/drt_fast/out/prod01_drt/prod01_drt.odb` for the probe,
`/work/drt_fast/out/prod01_drt8/prod01_drt8.odb` for the 8-iteration pass, and
`/work/drt_fast/out/prod01_drt16/prod01_drt16.odb` for the continuation. The
continuation ODB is copied byte-identically to
`build/production/baseline/routed.odb` (sha256
`a433816b…a40d07e`); keep the DRT logs and curves.

Gate: **MET** on `prod01_drt16.odb` — **0 DRT violations**, with a 0-byte
`prod01_drt16.drc`. The earlier 3,805-violation result is superseded.
`DRT-RESIDUE-001` below is **withdrawn** (never signed) and retained only as a
record of the residue before the continuation.

**Waiver `DRT-RESIDUE-001` — WITHDRAWN, never signed (superseded by the
zero-violation `prod01_drt16` pass).** Recorded 2026-11-19 against the completed
8-iteration pass, not the probe. It is retained only as a record of the residue
that the continuation removed; it is not in force and covers nothing.

- Database: `drt_fast/out/prod01_drt8/prod01_drt8.odb`, sha256
  `1bd7e7e23991f6484f42300535323489187cb76a0148cc4d07294f15d593ff07`, routed from
  `pre_drt_sssetup4.odb` (`dc2d325b…0eb0`) with OpenROAD `dcf36133…`, Metal1–Metal5,
  8 threads, `or_seed 42`.
- Residual: **3,805** detailed-route violations (DRT-0199 / `prod01_drt8.drc`),
  **0.95%** of the first-iteration count, on a monotone decreasing curve with no
  guard stop.
- Categories and layers (router classes, not foundry deck rule IDs):

| Router class | Count | Layers |
|---|---:|---|
| Short | 3,295 | Metal2 2,033; Metal3 844; Metal4 367; Metal5 36; Metal1 15 |
| Metal Spacing | 503 | Metal2 281; Metal3 134; Metal5 51; Metal4 28; Metal1 9 |
| NS Metal | 4 | Metal2 4 |
| Cut Spacing | 2 | Via2 1; Via3 1 |
| Cut Short | 1 | Via2 1 |
| **Total** | **3,805** | Metal2 2,318; Metal3 978; Metal4 395; Metal5 87; Metal1 24; Via2 2; Via3 1 |

- Composition: 1,976 distinct shorted net pairs (767 of them carry more than one
  marker); 134 shorts
  involve a `clknet_*` net and 126 involve VDD or VSS (VSS in 79, VDD in 47).
  Shorts span x 578.9–2,008.6 µm, y 1,097.8–3,736.0 µm; the densest 500 µm cells
  are x 500–1,000 / y 2,000–2,500 with 777, x 1,500–2,000 / y 1,000–1,500 with
  571, and x 1,000–1,500 / y 2,000–2,500 with 434.
- Basis for acceptance at Stage 3: the pass converged monotonically with the guard
  attached, every marker is enumerated in the `.drc`, and the residue is confined
  to detailed routing. This unblocks Stage 4 route QA and GDS assembly for
  development.
- What this waiver does **not** assert: that the database is DRC-clean,
  electrically functional, manufacturable or tape-out ready. The 3,295 shorts are
  electrical failures, and 134/126 of them touch clock/power nets. It does not
  cover full-deck DRC (KLayout/GF deck), LVS, antenna, STA/power/IR/EM, or any
  later database, and it is void if the ODB or count changes.
- Conditions: (1) Stage 4 records this residue as known and does not present the
  resulting GDS as DRC-clean; (2) any further DRT arm or ECO supersedes this
  waiver and requires a new count; (3) foundry/tape-out acceptance needs its own
  numbered waiver on the final GDS; (4) the waiver is re-validated if the router,
  deck, seed, layer range or input ODB changes.
- Owner signature: ______________________________  Date: ____________
  Design lead: ______________________________  Date: ____________

### Stage 4 — Route QA, then build the pre-ECO GDS

Export the routed DEF and the post-route Verilog from the ODB in the flow image:

```bash
docker run --rm \
  -v /mnt/HC_Volume_107515356/grx930_ol2:/work -w /work \
  gf180mcu-precheck:arm64 openroad -no_init -exit <<'EOF'
read_db /work/build/production/baseline/routed.odb
write_def /work/build/production/baseline/routed.def
write_verilog /work/build/production/baseline/grx930_test_chip_routed.v
EOF
```

Build the CDL from that netlist and check the routed DEF against it. This is also
the CDL G0/G2 will freeze, so build it here rather than at the end:

```bash
SRC=/home/ubuntu/grx930_stage2
ROOT=/mnt/HC_Volume_107515356/grx930_ol2
runpy() {
  docker run --rm \
    -v "$ROOT:/work" -v "$SRC:/src" -w /work \
    --entrypoint python3 ghcr.io/efabless/openlane2:2.3.10 "$@"
}
# $SRC is the clean Stage 2 worktree; $ROOT is the flow volume. The Stage 0
# inputs (c930/asic_gf180mcu/build/cells.lef and
# build/lvs_chip/pdk_fd_sc_mcu7t5v0.gds) must be staged under $SRC first: on
# 2026-11-19 neither existed on the production host.
# The flow top is chip_top; the GDS top (and the deck's `topcell`) is
# grx930_test_chip. Add `--top` to mk_chip_cdl.py so the CDL's .SUBCKT matches
# the layout, instead of renaming the netlist or the deck.
runpy /src/c930/asic_gf180mcu/tools/lvs_chip/mk_chip_cdl.py \
  --routed /work/build/production/baseline/grx930_test_chip_routed.v \
  --top grx930_test_chip \
  --out /work/build/production/baseline/grx930_test_chip.cdl
runpy /src/c930/asic_gf180mcu/tools/lvs_chip/net_compare.py \
  --def /work/build/production/baseline/routed.def \
  --cdl /work/build/production/baseline/grx930_test_chip.cdl \
  --json /work/build/production/baseline/net_compare.json
```

`net_compare` answers connectivity, not coverage: a net can have both pins and no
wire and still match. Add one small OpenDB pass over the routed database that
counts multi-terminal signal nets with no `Wire`/`SWire` and any net with fewer
than two terminals; the audit DEF had 1,022 and 2 of that class. It is a loop over
`ord::get_db_block`, not a new checker.

**DEF-defined vias.** `stream_out.py` accepts only LEF `VIA` names, and a routed
DEF may define its own vias in a `VIAS` section instead. The old DEF has two:
`via3_4_3200_3200_3_3_1040_1040` and `via4_5_3200_6400_4_2_1240_1240`. Promote
them into a supplemental LEF; do not relax `stream_out.py` and do not read the
artifact. Run `promote_def_vias.py` (§4) after route export:

```bash
runpy /src/c930/asic_gf180mcu/tools/lvs_chip/promote_def_vias.py \
  --def /work/build/production/baseline/routed.def \
  --lef /src/c930/asic_gf180mcu/build/cells.lef \
  --out /work/build/production/baseline/routed_vias.lef
```

For every `VIAS` entry, require `+ VIARULE <name>` (naming a
`VIARULE ... GENERATE` block in the LEF), `+ CUTSIZE w h`, `+ LAYERS lower cut
upper`, `+ CUTSPACING sx sy`, `+ ENCLOSURE e1 e2 e3 e4`, and `+ ROWCOL rows cols`.
Read the DEF's `UNITS DISTANCE MICRONS` (2000 here), convert to microns, and
emit a fixed `VIA <name>` block:

- `pitch_x = w + sx`, `pitch_y = h + sy`; DEF `CUTSPACING` is edge-to-edge, so
  the pitch is cut size plus spacing. Cut centres are
  `(i - (cols-1)/2) * pitch_x` and `(j - (rows-1)/2) * pitch_y`;
- the lower-metal rect spans `cols*w + (cols-1)*sx + 2*e1` by
  `rows*h + (rows-1)*sy + 2*e2`;
- the upper-metal rect spans the cut field plus `2*e3` by `2*e4`;
- one `RECT` per cut on the cut layer, one per metal.

`e1`/`e2` enclose the lower metal in x/y and `e3`/`e4` the upper metal. This is
the DEF convention, not the LEF `VIARULE` `ENCLOSURE` pair.

`LAYERS` must name the same lower, cut, and upper layers as the named VIARULE
(identified by role; the VIARULE block lists lower, upper, cut), and its cut RECT
must equal `CUTSIZE`. The DEF's `CUTSPACING` and `ENCLOSURE` win over the
VIARULE's generator defaults; the two old entries differ from
`Via3_GEN_HH`/`Via4_GEN_HH`, so copying those defaults would silently change the
via. Refuse with status 2 on a missing or unknown token, unknown VIARULE,
layer-role or cut-size mismatch, non-positive dimension, `VIAS` count mismatch,
or a name already defined in the LEF. A bare `VIARULE` name used as a via without
a `VIAS` entry is still refused; the router must emit the `VIAS` definition or use
a LEF via. Never fall back to the artifact.

The formula reproduces the old DEF exactly: 9 cuts with 1.42 × 1.60 µm and
1.60 × 1.42 µm metals, and 8 cuts with 1.60 × 2.24 µm and 1.00 × 2.58 µm metals.
A `test_promote_def_vias.py` regression uses those two entries as fixtures,
feeds the generated LEF through `stream_out.parse_lef_vias`, and checks every
refusal; it reads no design or artifact.

Then build the pre-ECO GDS in the documented order:

```bash
runpy /src/c930/asic_gf180mcu/tools/lvs_chip/fill_def.py \
  --def /work/build/production/baseline/routed.def \
  --lef /src/c930/asic_gf180mcu/build/cells.lef \
  --out /work/build/production/baseline/filled.def
runpy /src/c930/asic_gf180mcu/tools/lvs_chip/stream_out.py \
  --def /work/build/production/baseline/filled.def \
  --lef /src/c930/asic_gf180mcu/build/cells.lef \
  --lef /work/build/production/baseline/routed_vias.lef \
  --routing def --out /work/build/production/baseline/pre_eco_stream.gds
runpy /src/c930/asic_gf180mcu/tools/lvs_chip/pdn_stitch.py \
  --def /work/build/production/baseline/filled.def \
  --gds /work/build/production/baseline/pre_eco_stream.gds \
  --out-gds /work/build/production/baseline/pre_eco.gds \
  --report /work/build/production/baseline/strap_report.json
runpy /src/c930/asic_gf180mcu/tools/lvs_chip/stream_check.py \
  --gds /work/build/production/baseline/pre_eco.gds \
  --def /work/build/production/baseline/filled.def \
  --lib /src/c930/asic_gf180mcu/build/lvs_chip/pdk_fd_sc_mcu7t5v0.gds
```

`stream_out.py` reads the PDK cell GDS for cell layouts and the LEF's `VIA`
definitions for via cells; `--lef` is repeatable, and every via token the DEF
names must be defined in one of them. The routed DEF must therefore use LEF vias
only: a DEF `VIAS` section is promoted above, not approximated from the old
layout. The PDK GDS and base LEF are pinned in Stage 0; `routed_vias.lef` is
generated here and hashed into G0. If the router emits no `VIAS` section, the
promoter writes a header-only LEF and the command still passes both files. The
supplemental file contains only `VIA` blocks, so layer widths stay from
`cells.lef`; the promoter also refuses a name already in the base LEF, so
`stream_out`'s first-definition-wins lookup cannot silently prefer the wrong
geometry. The artifact is not read in `--routing def` mode.

Output: `routed.def`, `routed_vias.lef`, `grx930_test_chip_routed.v`,
`grx930_test_chip.cdl`, `filled.def`, `pre_eco.gds`, `strap_report.json`,
`net_compare.json`.

Gate: `net_compare` MATCH; 0 unrouted signal nets and 0 zero/one-terminal nets
from the OpenDB pass; the CDL top is `grx930_test_chip`, the same name the GDS top
and the G2 deck use; every DEF `VIAS` entry was promoted into `routed_vias.lef`,
and `stream_out.py` built every via from a LEF definition and refused none; fill
and stitch exit 0 with no refused island; stream check passes.

### Stage 5 — Derive the new ECO site list

Build `find_eco_sites.py` on `pre_eco.gds` plus `filled.def`, using the legality
rules in `validate_drop_windows_2x2.rb`. The `sub` islands and the rail ends exist
only after the fill/stitch passes, so the routed ODB is the wrong source.

- Substrate tap islands from connected M1 components on the `sub` net.
- Legal VSS rows from the new VSS labels/strips; exclude any row whose only clean
  M2 corridor overlaps VDD (the row-300 rule, generalized).
- Rail-end drops from the new power-rail geometry; do **not** look for the old
  `$45264` name.
- 0.84 µm M2 strap, 1.40 µm M2 keepout, 0.90 × 0.78 µm M1 landing,
  0.90 × 0.80 µm M3 landing, no VDD overlap.

Output: `eco_sites.csv` (name, x, y, ty, kind) and a report with
`N_sub + N_rows + N_rail = N`.

The CSV carries **GDS database units** (1 nm), the frame the stitched GDS and
`build_row_crops.rb` use. The DEF writer doubles them (2000 dbu/µm) and the
checker converts back with the same round-half-to-even rule as `stream_out.py`;
keep that conversion in one helper so a site cannot shift by half a DEF unit.

Gate: `N` is frozen from the report, every site legal, no duplicate rows, and the
generalized VDD exclusion holds. **Do not gate on 8,168.**

### Stage 6 — Insert the ECO into the DEF/ODB and the base GDS

One site list, two writers, so the DEF and GDS cannot drift:

1. **DEF/ODB** — `insert_eco_2x2.py` reads `filled.def` and `cells.lef` into
   OpenDB (run under `openroad -python`; preflight `import odb`), inserts the M1
   landing, the M2 strap, the M3 landing, and the Via1
   `Via1_2X2_0_60_10_60_H_V` / Via2 `Via2_2X2_0_60_10_60_V_H` arrays, then writes
   `eco_routed.def` and `eco_routed.odb`. Starting from `filled.def`, not the
   routed ODB, keeps the fillers and well taps. The filled DEF has no `sub` net
   (its `SPECIALNETS` are the supply nets), so create one with no terminals and
   attach the substrate drops to it; the DEF net name is not what G0 checks, and
   LVS reads the CDL, not this DEF. If the precheck image's OpenROAD has no
   `odb` Python module, write the ECO DEF statements directly instead; the GDS
   writer and the site list are unchanged.
2. **GDS** — `patch_eco_gds.rb` inserts the same geometry from the same
   `eco_sites.csv` into `pre_eco.gds` and writes
   `build/production/final/grx930_test_chip_final.gds`. This is the 13-site
   `build_row_crops.rb` method extended to the full list, using the 2×2 `VIA`
   definitions from `cells.lef`: M1 landing, M2 strap with 0.45 µm extension past
   each via centre, M3 landing, 0.26 µm cuts on 0.52 µm centres.

Do **not** re-stream the ECO DEF. The 2×2 vias are now buildable from the LEF, but
a re-stream would produce a new `pre_eco` frame and lose the GDS-only stitch
straps; patching the existing `pre_eco.gds` keeps the base/final delta exactly the
inserted geometry.

Run the DRC/landing checks on **all** sites, not the 13-site crop, and compare
before/after reports.

Output: `eco_routed.odb`, `eco_routed.def`, `final/grx930_test_chip_final.gds`,
`eco_drc.rlyrdb`, `eco_landing.log`.

Gate: 0 added M1/M2/M3/V1/V2 findings; `N` of each 2×2 via; no VDD overlap; M1/M3
landing coverage met; M2 keepout respected.

### Stage 7 — G0 geometry checks

The checks are window-based, not full-chip: the pre-ECO GDS carries the
`pdn_stitch` M2 straps that the DEF does not, so a whole-die Metal XOR can never
be zero. Compare only the ECO windows, where base and final differ by exactly the
inserted geometry.

- `gds_checks.rb -rd gds=final.gds -rd base=pre_eco.gds -rd def=eco_routed.def
  -rd topcell=grx930_test_chip -rd expected_die_w=<DEF die>
  -rd expected_die_h=<DEF die> -rd expected_drops=<N> -rd report=...` — counts new
  260 × 260 Via2 cuts, requires `4N`, and checks the die.
- Change `def_gds_checks.rb` to take `-rd base=pre_eco.gds` and
  `-rd sites=eco_sites.csv`, and compare, inside each site window,
  `(final.gds − base.gds)` against `(eco_routed.def − filled.def)`. Count the 2×2
  Via1/Via2 drops from the DEF anchors and require `N`, and assert that the GDS
  delta is contained in the site windows. Drop the hardcoded `ROW300_*` box: the
  generalized VDD exclusion is enforced when the site list is frozen (Stage 5),
  and the old box names coordinates this baseline will not have.
- Remove the old row-300 box from `gds_checks.rb` as well. It is a gate
  (`row300_new == 0`), so on a new floorplan it can only fail spuriously; the
  exclusion belongs in the site list, not in a fixed rectangle.

Run both checkers once, through the parameterized G0 in Stage 9; do not duplicate
the invocations here.

Gate: both checkers exit 0; zero XOR inside every site window; `N` Via1 and Via2
drops; no new geometry outside the windows.

### Stage 8 — Extract SPEF with OpenRCX — CLOSED WITH RECORDED EXCEPTION

Status (2026-11-21): nominal-corner RCX extraction completed and validated.
Closure record: `build/production/baseline/stage8/STAGE8_CLOSURE.md`.

The pinned OpenROAD build is `dcf36133a369abc8f3c5e5738cd4d82e4903c0e0`; the
`nom` RCX rules are
`/workspace/gf180mcu/gf180mcuD/libs.tech/librelane/rules.openrcx.gf180mcuD.nom`
(SHA-256 `d83a04ea…62ddf`). The successful command was:

```tcl
read_db /work/build/lvs_chip/eco_drop_2x2/stage6/eco_routed.odb
extract_parasitics -ext_model_file /workspace/gf180mcu/gf180mcuD/libs.tech/librelane/rules.openrcx.gf180mcuD.nom
write_spef /work/build/production/final/grx930_test_chip.spef
```

`define_process_corner -ext_model_index 0 <file>` alone left the model filename
empty in this build (`RCX-0468`); the single-corner `-ext_model_file` form loaded
the same model and defined `MinMax0`. Output: 188,709,802 bytes, SHA-256
`f4d4b6f2…e91410b0`, 125,214 `*D_NET`s. The sidecar
`build/production/final/grx930_test_chip.spef.corner` records `corner=nom`.

Coverage: 126,236 DEF signal nets; 1,022 have fewer than two terminals and no
wire, so 125,214 are annotated. The 1,022 are **accepted as a recorded
exception**: they have no wire geometry from which to form a SPEF RC network, and
the audit found none are clock nets. This is a coverage exception, not an
LVS/DRC waiver.

Clock: the only clock net, `i_clk`, is annotated. Delivered SPEF `*D_NET *1`
68.7184 pF; `report_net` reports 68.71 pF wire and 179.77 pF total; a clock-only
`write_spef -nets {i_clk}` subset contains 227,050 `*CAP` and 65,248 `*RES`
entries. `read_spef` found 0 unannotated and 0 partially unannotated drivers.

`diff_spef`: the Tcl wrapper in this build ignores `-r_res`/`-r_cap`/
`-r_cc_cap`/`-r_conn` and tests an undefined `-over` flag, so the value-enabled
comparison was invoked as `rcx::diff_spef <spef> 1 1 1 1 -1 -1`. It returned 0
with no numeric-difference lines and exactly the expected 1,022 missing nets
(plus 236,696 tapcell instances with no signal-net SPEF entry). A full
re-extraction reproduced the delivered SPEF byte-for-byte after excluding
`*DATE`, with the same 188,709,802 bytes and 125,214 `*D_NET`s.

Gate: **PASS WITH RECORDED EXCEPTION** for net-count equality
(125,214 + 1,022 = 126,236); no unannotated clock nets; `nom` corner sidecar
exists; `read_spef` and value-enabled `diff_spef` succeed. Min/max SPEFs were not
produced; repeat only if the signoff corners require them.

Evidence: `spef_extract.log`, `spef_readback.log`,
`spef_clock_annotation.log`, `stage8_coverage_audit.log`,
`spef_diff_values.log`, and `spef_reextract.log` under
`build/production/sta/`.

### Stage 9 — Freeze, G0, and G2

- Add environment overrides to `g0_freeze.sh` and `g2_lvs.sh` rather than editing
  constants per run: `G0_GDS`, `G0_CDL`, `G0_DEF`, `G0_SPEF`, `G0_BASE`,
  `G0_DIE_W`, `G0_DIE_H`, `G0_DROPS`, `G0_SITES`, `G0_VIAS_LEF`, and the
  matching `G2_*`. Keep the current paths as defaults, so the VOID package's
  state is unchanged. The old row-300 rectangles in both checkers are removed
  rather than parameterized; the site list is the only place that rule can be
  stated correctly.
- Run `g0_freeze.sh` with `G0_BASE=pre_eco.gds`, `G0_DROPS=<N>`,
  `G0_SITES=eco_sites.csv`, `G0_VIAS_LEF=routed_vias.lef`, and the new
  GDS/CDL/DEF/SPEF. Require
  `status=READY_FOR_REVIEW`, `gds_checks=PASS`, `def_gds_checks=PASS`,
  `no_void=PASS`, and a manifest hash.
- Fill `G0_signoff.txt` with a **Gridworkz-authorized** signer. Do not fabricate it.
- Run `g2_lvs.sh` with the new GDS/CDL/DEF/SPEF; full-chip LVS uses the frozen
  GDS and CDL and the pmap-capable image. The DEF and SPEF are hash-gated inputs,
  not deck inputs. Historical full-chip LVS cost is ~5,983 s.

Gate: G0 signed; G2 completes with 0 mismatches; report and netlist archived.

## 4. Pieces that must be built

1. **ECO site finder** — GDS/DEF replacement for the missing `chip.l2n` logic,
   with a generalized VDD exclusion and no dependence on `$45264`.
2. **ECO inserter** — one site list consumed by an OpenDB DEF/ODB writer and a
   KLayout GDS patcher.
3. **DEF `VIAS` promoter** — implemented in `promote_def_vias.py`; it parses
   only the DEF `VIAS` section, cross-checks each `+ VIARULE` against the LEF,
   and writes `routed_vias.lef` from the DEF's cut/enclosure/rowcol values. It is
   a pure DEF+LEF transform and never reads the artifact.
4. **All-site DRC/landing harness** — extend the 13-site checks to every row and
   rail.
5. **CDL top override** — a `--top` option for `mk_chip_cdl.py`, because the flow
   top (`chip_top`) is not the GDS/deck top (`grx930_test_chip`).
6. **Window-based `def_gds_checks.rb`** — `base` + `sites` instead of a
   whole-die XOR and a fixed row-300 box.
7. **SPEF extraction Tcl** — one corner per process, verified commands only.
8. **G0/G2 parameterization** — die, count, paths, site list, and promoted LEF via
   environment.
9. **Baseline manifest and signoff form** — one pinned set of hashes from RTL to
   SPEF.

## 5. Compute and schedule risks

| Risk | Evidence / bound | Mitigation |
|---|---|---|
| DRT divergence | v8 ran 10.6 days over 26 iterations; best 237,089 violations at iter 16, then 711,100; the last ODB is kept, not the best | `drt_curve_guard.sh` budgets and kill; short probe first; never ship a diverged ODB |
| DRT memory | measured peaks 6.4–7.0 GB; Docker died under a 5.8 GiB container; pre-DRT gate wants 12 GB | `gate.sh`, 16 GB host, one arm at a time |
| Disk exhaustion | a GRT overflow arm filled a 150 GB volume; flat stream GDS 509 MB, merged 392 MB, plus ODBs | 150 GB free; `disk_guard.sh`; delete intermediate ODBs |
| GRT 0.2 abort | assembled die aborts with `GRT-0183` at 0.2; 0.1 is the landed value | keep 0.1; verify `Global adjustment: 10%` before DRT |
| Antenna repair abort | at 0.1 the die's `repair_antennas` can abort with `GRT-0183`; the landed arm relies on the catch | keep `lln_antenna_catch.sh`; archive the antenna log; do not read a caught abort as an antenna pass |
| ECO count is not 8,168 | the old list depends on fix16 `sub` islands, old VSS rows, and the old `$45264` net (§1.1) | derive `N`; parameterize G0/checkers; retire 8,168 with the old identity |
| CDL/GDS top mismatch | flow `DESIGN_NAME: chip_top`; `stream_out.py` writes the GDS top as `grx930_test_chip`; the deck takes `topcell=grx930_test_chip` | write the CDL with `--top grx930_test_chip` and gate on it before G0 |
| DEF `VIAS` is not streamable as-is | `stream_out.py` accepts only LEF `VIA` names; the old DEF has two `VIAS` entries | run `promote_def_vias.py` after route export, pass `routed_vias.lef` as a second `--lef`, hash it in G0; refuse incomplete entries; never fall back to the artifact |
| VOID artifact in the GDS path | `--routing def` no longer reads the artifact; only `--routing artifact` does, for re-checking the September die | keep `--routing artifact` out of the fresh-baseline stages |
| DEF/GDS mismatch outside the ECO | `pdn_stitch` writes M2 straps to the GDS only | window-based check; do not gate on a whole-die Metal XOR |
| ECO legality | 4,318 pre-existing full-chip DRC findings; 0-added requirement over all sites; 1.40 µm M2 keepout | all-site DRC, resites, generalized VDD exclusion |
| Runtime | full flow to pre-DRT days; DRT 1.5–10+ days per pass; fill/stream/stitch hours; LVS ~100 min; DRC ~10 min; RCX hours/corner; STA corners hours | dedicated machine, one baseline tag, checkpoint every step |
| Identity drift | legacy synth netlist, audit DEF, and die database; stale 3930×5120 references vs the 3932×5122 authority; unsupported keys `FP_DIE_AREA`/`DRT_ALLOW_CONGESTION` in the 2.3.10 log | Stage 0 freezes one RTL entry and 3932×5122; old synthesized netlists are excluded; use supported keys |
| RCX rules absent locally | local PDK `RCX_RULES` is empty; Stage 1 found the image rules at `gf180mcuD/libs.tech/librelane/`, with hashes in `stage1/toolchain_versions.txt` | use the verified `librelane` path; do not use the stale `openlane` path |
| Precheck image present | Stage 1 pulled the pinned index digest; image ID and size are in `stage1/STAGE1_VERIFICATION.md` | image present; PDK/RCX checks pass; host readiness gate PASS; Stage 2 not started |
| PDK/OpenROAD identity | Stage 0 re-pinned to image CIEL/Open_PDKs `792ef…` and OpenROAD `dcf3613…`; no `volare`; pad ring/mask comparison found no edits | use only these pins; the production readiness gate is PASS |
| Signoff | no Gridworkz connector; G1 DFT/ATPG absent; G3 waiver and G4 STA/power open | external signoff; do not claim a pass without receipts |

## 6. Planning envelope

Assuming one engineer, one dedicated 16 GB/150 GB machine, the PDK and RCX rules
available, and DRT converging in the historical 0.1 regime:

- Stage 0–1: 1–2 days.
- Stage 2 (RTL to pre-DRT): 1–3 days.
- Stage 3 (DRT): 1–10+ days; the largest variance.
- Stage 4 (VIAS promoter + QA + fill/stream/stitch/CDL): 2–3 days.
- Stage 5 (ECO list): 3–5 days.
- Stage 6 (ECO insert + all-site DRC): 1–2 weeks; the largest engineering risk.
- Stage 7 (geometry checks): 1 day.
- Stage 8 (RCX/SPEF): 1–3 days.
- Stage 9 (freeze/LVS): 1–2 days, plus Gridworkz signoff latency.

G0/G2 artifacts: roughly **4–8 weeks** after Stage 0. G3 DRC disposition, G4 STA/
power/IR/EM, G1 DFT/ATPG, and G5 foundry review are additional weeks to months and
are outside this plan.

## 7. Explicitly not done

Stage 1 pulled the pinned image and ran only read-only version, path, and hash
probes plus an OpenROAD command-help check; Stage 1 did not run `ws_exec.sh`, DRT,
stream-out, ECO insertion, or OpenRCX. Stage 2 was started on 2026-11-18:
the source fetch, target worktree, gate rerun, template staging and `ws_exec.sh`
launch were performed. Its GRT/PDN acceptance gate has not yet been evaluated;
no DRT, stream-out, ECO insertion, or OpenRCX command has been run. The staging
block was rehearsed first in a disposable local root
(`build/production/stage2_staging_simulation.sh`, 49/49 checks). The Stage 0 PDK/GDS/LEF pins were
updated to the image's 792 identity (see `baseline/stage0/IDENTITY.md`), and the
pad-ring/mask comparison is recorded in
`baseline/stage1/PAD_RING_MASK_COMPARISON.md`. Read-only inspection, a parser test
of the new LEF via reader, and a KLayout check of the 2×2 cell it builds were
run; no DEF was streamed. G0 remains `BLOCKED`, G2 exits 2, and the package
remains **VOID — DO NOT SUBMIT**.
