# Stage 1 — Toolchain and PDK verification

**Status: BLOCKED — PDK COMMIT AND OPENROAD BUILD MISMATCH. No synthesis, P&R,
DRT, stream-out, ECO insertion, or RCX has run.** The submission package remains
**VOID — DO NOT SUBMIT**; G0 and G2 remain `BLOCKED`.

The pinned image was pulled by OCI index digest and inspected read-only. The
image is usable, and the three RCX rule files are present and readable, but the
image does **not** contain the Stage 0 PDK commit or the Stage 0 expected
OpenROAD build. Stage 1's gate is therefore **not met**, and Stage 2 must not
start under the frozen identity.

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

The first pull failed with `unexpected EOF` after all layers reported complete.
A retry stalled before registry progress and was cancelled. The final pull used
an explicit `--platform linux/amd64` and succeeded:

```text
Digest: sha256:104d9ccbc0d3e4bbffba6201b7f68cd8f64d064b5b9072b64a3a4c926d46339f
Status: Downloaded newer image for ghcr.io/wafer-space/gf180mcu-precheck@sha256:104d9ccbc0d3e4bbffba6201b7f68cd8f64d064b5b9072b64a3a4c926d46339f
```

Successful pull log:
`build/production/logs/stage1_pull_retry2.log`.
The failed first pull is retained at `build/production/logs/stage1_pull.log`.

## PDK verification — FAIL (commit mismatch)

| Item | Stage 0 pin | Image observation |
|---|---|---|
| PDK | `gf180mcuD` | `gf180mcuD` |
| Root | `/workspace/gf180mcu` | `/workspace/gf180mcu` |
| PDK commit | `0fe599b2afb6708d281543108caf8310912f54af` | **not present** |
| PDK manager/source | `volare fetch --pdk gf180mcu 0fe599b2…` | `ciel`; `SOURCES` says `open_pdks 792ef67037d74c8c51811eab3ce23cf793491296` |
| Resolved target | — | `/workspace/gf180mcu/ciel/gf180mcu/versions/792ef67037d74c8c51811eab3ce23cf793491296/gf180mcuD` |
| Open_PDKs version/commit | — | `1.0.616` / `792ef67037d74c8c51811eab3ce23cf793491296` |
| `gf180mcu_pdk` reference | — | `a897aa30369d3bcec87d9d50ce9b01f320f854ef` |
| Git metadata | — | no `.git` directory |

The image's `gf180mcuD` is a symlink into CIEL's `792ef…` version directory.
The `SOURCES` file and `nodeinfo.json` both identify Open_PDKs commit
`792ef67037d74c8c51811eab3ce23cf793491296`; the nodeinfo's underlying
`gf180mcu_pdk` reference is `a897aa30369d3bcec87d9d50ce9b01f320f854ef`. A
recursive search of the CIEL PDK tree found no reference to
`0fe599b2afb6708d281543108caf8310912f54af`. `volare` is **not installed** in the
image; `ciel` 3.1.0 is.

This is not a cosmetic version label: Stage 0 pins a Volare PDK commit, while the
image carries a CIEL/Open_PDKs build. They are different identities and must not
be mixed. **`pdk_commit_verified=NO`.**

## RCX rules — PRESENT and readable

The Stage 1 plan expected these under the PDK's OpenLane directory. In this image
they are under `libs.tech/librelane/`, so the Stage 8 path in the plan was
incorrect and has been corrected.

| Corner | Path | Bytes | SHA-256 |
|---|---|---:|---|
| `nom` | `.../libs.tech/librelane/rules.openrcx.gf180mcuD.nom` | 31,291 | `d83a04ea28af9b74a097fb479bbab9ed52859a1e3428b33d3151cb5afae62ddf` |
| `min` | `.../libs.tech/librelane/rules.openrcx.gf180mcuD.min` | 31,290 | `5cf275c985ffd49096407d22891910fea34aff5a915db8a5b9a7c1e04b737e00` |
| `max` | `.../libs.tech/librelane/rules.openrcx.gf180mcuD.max` | 31,286 | `0ee103cf2108f2fd945087551b6dd1eaf4ee55af60571de2983878c8a271515f` |

All three begin with `Extraction Rules for OpenRCX`, declare `LayerCount 5`, and
are non-empty. The `.nom.magic`, `.min.magic`, and `.max.magic` variants are also
present. **RCX file presence/readability is PASS**, but extraction cannot be
qualified against a PDK/OpenROAD identity that does not match Stage 0.

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

Stage 0's Stage 8 notes were verified against OpenROAD
`edf00dff99f6c40d67a30c0e22a8191c5d2ed9d6`. The pulled image reports
`dcf36133a369abc8f3c5e5738cd4d82e4903c0e0` instead. **OpenROAD pin
verified=NO.** The Stage 8 `define_process_corner`/`extract_parasitics`/
`write_spef` command set has not been revalidated against the image's build.

## Gate result

| Check | Result |
|---|---|
| Image pull by pinned index digest | `PASS` |
| Image is linux/amd64 at the pinned digest | `PASS` |
| In-image PDK commit equals Stage 0 `0fe599b2…` | `FAIL` — image has CIEL/Open_PDKs `792ef670…` |
| `rules.openrcx.gf180mcuD.{nom,min,max}` present/readable | `PASS` (at `libs.tech/librelane/`) |
| OpenROAD build equals Stage 0 expected `edf00dff…` | `FAIL` — image has `dcf36133…` |
| Stage 1 gate | **NOT MET** |
| Synthesis / P&R / RCX | `NOT_RUN` |
| G0 / G2 | `BLOCKED` / `BLOCKED` |
| Package | `VOID — DO NOT SUBMIT` |

## Required resolution before Stage 2

Do not silently substitute versions. Choose one identity and freeze it anew:

1. **Re-pin to this image:** make a new Stage 0 identity using the image's
   CIEL/Open_PDKs `792ef…` PDK and OpenROAD `dcf3613…`, then revalidate the flow
   and the Stage 8 RCX commands against that build; or
2. **Keep the existing Stage 0 identity:** obtain an image containing PDK
   `0fe599b2…` and OpenROAD `edf00dff…` (or build/fetch them into a controlled
   image), then repeat this Stage 1 verification.

Until one is done, Stage 2 must not start. No flow command was run for this
record; the only container commands were read-only version, path, and hash
probes. The existing submission remains VOID and no signoff is claimed.

## Evidence

Machine-readable pins and hashes:
`build/production/baseline/stage1/toolchain_versions.txt`.

Key commands (run with `MSYS_NO_PATHCONV=1` on this Windows host):

```bash
docker image inspect "$REF" --format 'Id={{.Id}} ...'
docker run --rm "$REF" sh -lc 'librelane --version; openroad -version; klayout -v'
docker run --rm --entrypoint /bin/sh "$REF" -lc 'cat "$V/SOURCES"; find ...'
docker run --rm "$REF" sh -lc 'sha256sum "$PDK/gf180mcuD/libs.tech/librelane/rules.openrcx.gf180mcuD."{nom,min,max}'
```
