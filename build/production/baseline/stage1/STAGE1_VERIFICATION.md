# Stage 1 — Toolchain, PDK, and host readiness verification

**Status: PASS — PDK/RCX/IMAGE AND PIN CHECKS PASS; STAGE 1 RESOURCE READINESS
GATE PASSES ON THE PRODUCTION HOST (197 GiB FREE).** The Stage 0 identity was
updated to the versions already present
in the pinned flow image. No synthesis, P&R, DRT, stream-out, ECO insertion, or
RCX has run. The submission package remains **VOID — DO NOT SUBMIT**; G0 and G2
remain `BLOCKED`.

The earlier mismatch was resolved by changing the Stage 0 identity, not by
substituting a different image or by mixing the `0fe`/`edf` build with the
`792`/`dcf` one. The old `0fe599b2…` / `edf00dff…` pins are no longer active.

## Pull result

| Item | Value |
|---|---|
| Registry reference | `ghcr.io/wafer-space/gf180mcu-precheck@sha256:104d9ccbc0d3e4bbffba6201b7f68cd8f64d064b5b9072b64a3a4c926d46339f` |
| Pulled index digest | `sha256:104d9ccbc0d3e4bbffba6201b7f68cd8f64d064b5b9072b64a3a4c926d46339f` |
| `docker image inspect` Id | `sha256:104d9ccbc0d3e4bbffba6201b7f68cd8f64d064b5b9072b64a3a4c926d46339f` |
| RepoDigests | same index digest |
| Platform | `linux/amd64` |
| Created | `2026-10-20T13:24:16.386377199Z` |
| Size | `13,694,512,890` bytes |
| Entrypoint / workdir | `dev-shell` / `/workspace` |
| Built-in env | `PDK_ROOT=/workspace/gf180mcu`, `PDK=gf180mcuD` |

Successful pull log:
`build/production/logs/stage1_pull_retry2.log`.

## PDK verification — PASS (re-pinned)

| Item | Stage 0 pin | Image observation |
|---|---|---|
| PDK | `gf180mcuD` | `gf180mcuD` |
| Root | `/workspace/gf180mcu` | `/workspace/gf180mcu` |
| PDK commit | `792ef67037d74c8c51811eab3ce23cf793491296` | `792ef67037d74c8c51811eab3ce23cf793491296` |
| PDK manager/source | CIEL/Open_PDKs | `ciel`; `SOURCES` says `open_pdks 792ef670…` |
| Resolved target | — | `/workspace/gf180mcu/ciel/gf180mcu/versions/792ef67037d74c8c51811eab3ce23cf793491296/gf180mcuD` |
| Open_PDKs version/commit | `1.0.616` / `792ef670…` | `1.0.616` / `792ef67037d74c8c51811eab3ce23cf793491296` |
| `gf180mcu_pdk` reference | `a897aa30369d3bcec87d9d50ce9b01f320f854ef` | same |
| Git metadata | — | no `.git` directory |

The image's `gf180mcuD` is a symlink into CIEL's `792ef…` version directory. The
`SOURCES` file and `nodeinfo.json` both identify Open_PDKs commit
`792ef67037d74c8c51811eab3ce23cf793491296`; the nodeinfo's underlying
`gf180mcu_pdk` reference is `a897aa30369d3bcec87d9d50ce9b01f320f854ef`.
`volare` is not installed in the image; `ciel` 3.1.0 is.

**`pdk_commit_verified=YES`.** The Stage 0 pin and the image now describe the
same PDK identity.

## RCX rules — PASS

The RCX rules are under `libs.tech/librelane/`, not `.../openlane/`. All three
are present, non-empty, and declare `LayerCount 5`:

| Corner | Path | Bytes | SHA-256 |
|---|---|---:|---|
| `nom` | `.../libs.tech/librelane/rules.openrcx.gf180mcuD.nom` | 31,291 | `d83a04ea28af9b74a097fb479bbab9ed52859a1e3428b33d3151cb5afae62ddf` |
| `min` | `.../libs.tech/librelane/rules.openrcx.gf180mcuD.min` | 31,290 | `5cf275c985ffd49096407d22891910fea34aff5a915db8a5b9a7c1e04b737e00` |
| `max` | `.../libs.tech/librelane/rules.openrcx.gf180mcuD.max` | 31,286 | `0ee103cf2108f2fd945087551b6dd1eaf4ee55af60571de2983878c8a271515f` |

The `.nom.magic`, `.min.magic`, and `.max.magic` variants are also present. These
hashes are unchanged from the earlier image inspection; `0fe` and `792` RCX files
were previously found byte-identical. **RCX presence/readability is PASS.**
Extraction itself has not run.

## Resource readiness — PASS

`c930/asic_gf180mcu/build/stage1_readiness.sh` is the explicit host gate. It
records the values and exits non-zero unless both memory floors and the volume
floor pass. The production target is `ubuntu@2.31.100.64`
(`ubuntu-32gb-fsn1-1`, aarch64), with source checkout
`/home/ubuntu/grx930` and deployed flow root
`/mnt/HC_Volume_107515356/grx930_ol2`.

The gate was run there on 2026-11-18:

| Check | Required | Recorded | Result |
|---|---:|---:|---|
| Pre-DRT available memory | 12 GiB (12,288 MiB) | 29,179 MiB (`MemAvailable`) | **PASS** |
| DRT-arm available memory | 8 GiB (8,192 MiB) | 29,179 MiB (`MemAvailable`) | **PASS** |
| Flow volume free | 150 GiB | 197 GiB | **PASS** |

The production record is at
`/mnt/HC_Volume_107515356/grx930_ol2/build/production/baseline/stage1/STAGE1_READINESS.txt`
and ends `status=PASS`. It is also copied to
`build/production/baseline/stage1/STAGE1_READINESS.txt` as the repository-side
production record; the earlier Windows/MSYS control is replaced.

The source checkout contains `stage1_readiness.sh`. Run the gate from there on
the target host:

```bash
ssh ubuntu@2.31.100.64
bash /home/ubuntu/grx930/c930/asic_gf180mcu/build/stage1_readiness.sh \
  --volume /mnt/HC_Volume_107515356/grx930_ol2 \
  --record /mnt/HC_Volume_107515356/grx930_ol2/build/production/baseline/stage1/STAGE1_READINESS.txt
```

Do not mark Stage 1 `MET` without a `STAGE1_READINESS.txt` record whose final
`status` is `PASS`. The production record now satisfies that condition.

## Toolchain pins

| Tool | Observed |
|---|---|
| LibreLane | `v3.1.0.dev3` |
| OpenROAD | git hash `dcf36133a369abc8f3c5e5738cd4d82e4903c0e0` |
| KLayout | `0.30.12` |
| Python | `3.13.13` |
| Nix | `2.35.3` |
| Magic | `8.3.677` (the image's PDK `nodeinfo` reports build Magic `8.3.685`) |
| Netgen | `Netgen 1.5.323` |
| Yosys | `0.69`, git sha1 `9f75ca1f9834a39a863915b5dae0c7b1e33533bc` |
| CIEL | `3.1.0` |
| Volare | **MISSING** |

Stage 0 now pins OpenROAD `dcf36133a369abc8f3c5e5738cd4d82e4903c0e0`.
**OpenROAD pin verified=YES.** A read-only OpenROAD help check on this build
found `define_process_corner`, `extract_parasitics`, and `write_spef`; no RCX was
run. `report_parasitics` remains absent and is not used.

## Pad-ring and precheck-mask comparison — PASS, no edits

Full record:
`build/production/baseline/stage1/PAD_RING_MASK_COMPARISON.md`.

| Check | Result |
|---|---|
| `slot_1x1` pad allocation | S17 / E20 / N17 / W20 = 74 pads |
| Current `mask_1x1.gds` | 74 pad apertures, all 60 × 60 µm; same allocation |
| 0fe vs 792 GDS layer 37/0 | **XOR empty** for every IO cell; both 60 × 60 µm at the same center |
| Pad cell footprints | 75 × 350 µm in both; fill and 355 × 355 µm corner unchanged |
| LEF `PAD` pin | 0fe 25 × 25 µm → 792 60 × 60 µm; LEF-only change |
| 792 `cor` LEF pin/OBS waiver | **`COR-LEF-PIN-OBS-001`** — interior via taps only; edge-rail pins exposed; no edits |
| `cor` edge-rail outward escape | **PASS** — 153/153 at 0.44 µm M5, 0 metal/metaltop DRC |
| `cor` external pad/via landings | **PASS** — 24/24, 0 metal/metaltop/via DRC |
| Metal5 minimum-width rule | **RESOLVED** — `MT.1` 0.44 µm governs 5LM; 0.38 µm LEF pin is an abstraction |
| Direct via on exposed edge rail | **CONSTRAINT** — no clear direct site; escape to landing pad |
| Pad-ring edit required | **NO** |
| Floorplan edit required | **NO** |
| `mask_1x1.gds` edit required | **NO** |

The 792 `cor` LEF also contains 13 pin/OBS overlaps documented as
`COR-LEF-PIN-OBS-001` in the pad-ring record. That is a LEF-only waiver: the
overlap is confined to interior via taps, all edge-rail pins remain exposed, and
no GDS or floorplan edit is required.

The focused pin-access evidence is in the same pad-ring record. The Metal5
minimum-width discrepancy is resolved: **`MT.1` (0.44 µm) governs Metal5 for
gf180mcuD `5LM_1TM_11K`**, matching the tech LEF; the generic `metal5` M5.1
0.28 µm check is not sufficient alone. The 0.38 µm value is a LEF pin
abstraction inside wider GDS metal, not a drawn M5 wire. A synthetic 0.38 µm
stub fails `MT.1`, while the 0.44 µm stub passes; all 153/153 edge shapes pass at
0.44 µm, and the 24-point external pad/Via3/Via4 test passes with `metaltop`
included. A direct via landing on the exposed edge metal is not available at the
tested locations (dense existing via arrays; no 0.40 µm-keepout clear site), so
fan out to a landing pad before via placement. This is DRC evidence only, not
router signoff.

The precheck pad check is `input(37,0).and(mask).xor(mask)`; it reads GDS layer
37/0, not the LEF `PAD` pin. Both PDK versions supply the 60 × 60 µm GDS openings
the current mask expects.

## Updated Stage 0 artifacts

| Artifact | Bytes | SHA-256 |
|---|---:|---|
| `c930/asic_gf180mcu/build/tech.lef` | 33,047 | `842b186318d53844561af4ec530b4e30d8ba519bcc58d512a363ef255acc7abd` |
| `c930/asic_gf180mcu/build/cells.lef` | 704,024 | `3a60c20f788fb14c6034c39490b4169418a7db3b5dfcbb791b1e137a115a5248` |
| `c930/asic_gf180mcu/build/lvs_chip/pdk_fd_sc_mcu7t5v0.gds` | 1,450,948 | `918955160002012d54d307273545bd72fe7e3ec4009efce02b7c2235a2fbaf67` |

`tech.lef` is the 792 `nom` tech LEF. `cells.lef` is that tech LEF with its final
`END LIBRARY` removed, followed by the 792 cell macros; it validates as 56 VIA
definitions, 229 macros, and one `END LIBRARY`.

## Gate result

| Check | Result |
|---|---|
| Image pull by pinned index digest | `PASS` |
| Image is linux/amd64 at the pinned digest | `PASS` |
| In-image PDK commit equals Stage 0 `792ef…` | `PASS` |
| `rules.openrcx.gf180mcuD.{nom,min,max}` present/readable | `PASS` (at `libs.tech/librelane/`) |
| OpenROAD build equals Stage 0 `dcf3613…` | `PASS` |
| Pad-ring/mask comparison; no edits required | `PASS` |
| `cor` pin-access escape/external-via evidence | `PASS` (`MT.1` 0.44 µm; direct via constrained) |
| Pre-DRT memory ≥ 12 GiB | **PASS** — 29,179 MiB on production host |
| DRT-arm memory ≥ 8 GiB | **PASS** — 29,179 MiB on production host |
| Flow volume ≥ 150 GiB | **PASS** — 197 GiB recorded on production host |
| Stage 1 gate | **MET — production readiness record `status=PASS`** |
| Synthesis / P&R / DRT / stream-out / RCX | `NOT_RUN` |
| Stage 2 | `NOT_STARTED` |
| G0 / G2 | `BLOCKED` / `BLOCKED` |
| Package | `VOID — DO NOT SUBMIT` |

The target production host has passed `stage1_readiness.sh`, and this record is
`status=PASS`. Stage 2 has not been started. Stage 8 RCX remains a later step and must run against this exact image,
PDK, and OpenROAD build; no RCX result is claimed here.

## Evidence

Machine-readable pins and hashes:
`build/production/baseline/stage1/toolchain_versions.txt`.
Host readiness evidence: the production record at
`/mnt/HC_Volume_107515356/grx930_ol2/build/production/baseline/stage1/STAGE1_READINESS.txt`,
with a repository-side copy at
`build/production/baseline/stage1/STAGE1_READINESS.txt`.

Key commands (run with `MSYS_NO_PATHCONV=1` on this Windows host):

```bash
docker image inspect "$REF" --format 'Id={{.Id}} ...'
docker run --rm "$REF" sh -lc 'librelane --version; openroad -version; klayout -v'
docker run --rm --entrypoint /bin/sh "$REF" -lc 'cat "$V/SOURCES"; find ...'
docker run --rm "$REF" sh -lc 'sha256sum "$PDK/gf180mcuD/libs.tech/librelane/rules.openrcx.gf180mcuD."{nom,min,max}'
```

The only flow-adjacent commands were read-only version/path/hash probes and the
OpenROAD `help` check. No design database was read and no flow step was invoked.
The focused `cor` pin-access check was also read-only; its synthetic layouts were
written only to `/tmp`, and the project GDS was not modified.
