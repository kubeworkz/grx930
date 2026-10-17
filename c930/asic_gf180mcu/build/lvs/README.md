# The LVS gate's evidence

`lvs_fixtures_verdict.json` is the committed verdict of the **fixture family** — the repo's first
green LVS, widened from one device to fourteen on 2026-10-17 and to **51 fixtures over six
families** later the same day. Each entry is one fixture from the PDK's own regression set, run
through the deck with the switches `build/lvs_fixtures.tsv` names:

| family | fixtures | what they cover |
|---|---|---|
| `mos_devices` | `nfet_05v0`, `pfet_05v0`, `nfet_03v3_dn`, `pfet_06v0` | n and p, a deep-nwell one, combine and implicit_connect |
| `res_devices` | `nplus_u`, `npolyf_s`, `pplus_u`, `nwell`, `ppolyf_u_2k`, `ppolyf_u_3k_6p0`, `tm11k` | diffusion, poly and well resistors; a non-default `poly_res` twice; a top-metal resistor |
| `mimcap_devices` | `cap_mim_2f0fF_B_5LM_2p0`, `cap_mim_1f5fF_A_1p5`, `cap_mim_1f0fF_B_6LM_1p0` | MIM caps on A/3LM, B/5LM and B/6LM |
| `bjt_devices` | **all 10**: `npn_00p54x02p00` … `npn_10p00x10p00`, `pnp_05p00x00p42` … `pnp_10p00x10p00` | NPN and PNP from 0.54×2 µm to 10×10 µm; only the smallest asks for `combine` |
| `diode_devices` | **all 15**: `diode_dw2ps_*`, `diode_nd2ps_*`, `diode_nw2ps_*`, `diode_pd2nw_*`, `diode_pw2dw_*`, `sc_diode` | every junction the deck knows, at 3.3 V and 6 V, with the `_dn` deep-nwell variants and the Schottky |
| `moscap_devices` | **all 12**: `cap_nmos_*`, `cap_pmos_*` | nmos/pmos MOS caps at 3.3 V and 6 V, the `_b` variant, and the `_dn` deep-nwell ones |

Those three are complete families: the manifest lists every fixture the PDK ships in them, so a
fixture added upstream is a visible diff rather than a silent omission.

`build/lvs_check.sh` judges it on every gate run: **0** pass, **1** mismatch (any fixture whose
devices or ports disagree, or a family about a different deck than the one on disk), **2**
cannot-run (no file, unreadable file, a fixture that skipped the port check). The full artifacts of
the original single-fixture run — deck log with `INFO : Congratulations! Netlists match.`, extracted
netlist, `.lvsdb`, negative controls — are in `Claude outputs/evidence_lvs_fixture/`, and the
settled deck defect is in `doc/lvs_plan.md` §6.

## The switches are the PDK's, not ours

Each manifest line carries the deck switches that fixture needs, taken from the PDK's own
regression config `testing/unit/<category>/config/default.yaml` at the pin. They are not taste:
every MOSFET fixture needs `combine=true` (otherwise each finger is its own device), the pfet and
pplus fixtures need `implicit_connect=true` (their fingers never join up without it), and a MIM cap
is only extractable on the metal stack its name names (`metal_level` + `mim_option` + `mim_cap`).
The diode, BJT and MOS-cap families added later brought three more: `consider_dn_dw_features=true`
for every `_dn` device (without it the DN/DW tubs are not part of the device), `implicit_connect`
for the two `pw2dw` diodes (their anode wells never join otherwise), and `combine` for `sc_diode`
and the smallest BJT. Those entries are not uniform inside a family — 7 of the 15 diodes and 4 of
the 12 MOS caps carry a non-default switch — which is why the switches live per line in the manifest
rather than per family. That config is fetched alongside the fixtures, and the column is no longer
trusted: `tools/lvs_switch_check.py` reads the pin's `testing/unit/<category>/config/default.yaml`
and compares every line with it, by key and by value. All 51 agree today (26 lines carry switches,
25 run on the harness defaults), and a line that does not agree stops the refresh **before the
first docker run** — exit 1, `LVS-EVIDENCE: SWITCHES`, the fixture and the key named. `--update`
accepts a stale family but cannot accept this, because a switch the PDK does not ask for is not a
family that moved; it is the evidence being built on a configuration nobody authorized.

The reader is deliberately narrow: it understands the two-level `test_switches:` map of scalars the
PDK writes, and answers CANNOT-RUN (not PASS) for anything else — a flow mapping, a third level,
tab indentation, a second top-level key. A config dialect this file does not implement must fail
loudly, because the alternative is a check that silently stops checking.

Fixtures the PDK ships but the manifest leaves out (`efuse_devices`, `mos_sab_devices`, `pads`,
`isosub`) are left out for cost: each line is a docker run of the deck, ~36 s here (51 in 30 minutes
of wall time), and each of those families needs its own switch work. `bjt_devices`, `diode_devices` and `moscap_devices`
left this list on 2026-10-17, when all 37 of their fixtures went into the manifest and came back
green.

## Keeping it honest (CI)

`.github/workflows/lvs-evidence.yml` re-runs the family against a **pinned copy of the PDK** and
compares: `CURRENT` (exit 0) if the committed evidence is still what comes out, `STALE` (exit 1) if
not, `BROKEN` (exit 1) if a fixture does not come back green — which never updates anything, because
a family that cannot reproduce itself is a finding about the pin, the switches or the PDK. It runs
when the files that could invalidate the evidence change, and weekly: the deck belongs to the PDK
upstream, so the pin can go stale without a commit here.

Before any of that, two cheap steps run: the switch check above, and
`build/lvs_switch_check_selftest.sh`, which proves the check still fails when it should — on a
synthetic pin, on the real one (one diode's `consider_dn_dw_features` removed), and through the
refresh script, where a disagreement must stop before a fixture runs and must survive both
`--update` and `--only`. Seconds, no docker pull; 21 cases, all green. A check nobody has seen fail
is the thing this step exists to prevent.

The pin is `355b9ee6b6f64327c8d5ac879dee597fe1e9c4b2`
(`fossi-foundation/globalfoundries-pdk-libs-gf180mcu_fd_pv`) — the revision whose deck and fixture
files hash to exactly what the evidence records. Upstream `main` is *not* a valid pin: its deck
differs, and evidence about it would mismatch on every machine that has this PDK.
`build/lvs_fetch_pdk_subset.sh` fetches the deck, the 26 `rule_decks` files it reaches
(transitively, each include resolved against the including file) and every fixture in the manifest,
and refuses to continue if a recorded hash disagrees — so a wrong pin fails in about ten seconds
instead of after a docker pull.

On a manual dispatch with `update: true` the job writes the refreshed evidence back and commits it.
Without that it is read-only and the fresh file arrives as an artifact, because a bot commit that
rewrites evidence under a green gate is the failure the gate exists to prevent.

## Regenerating it

```sh
cd <repo root>
bash c930/asic_gf180mcu/build/lvs_fetch_pdk_subset.sh      # the pin, hash-checked
bash c930/asic_gf180mcu/build/lvs_refresh_evidence.sh      # the family; says CURRENT or STALE
bash c930/asic_gf180mcu/build/lvs_refresh_evidence.sh --update   # accept a fresh family
```

Use `--only 'res_devices/*'` to iterate on one family without touching the committed file: it runs
what it was asked for and nothing else, judges and aggregates only that subset (the manifest
it builds from is written beside the runs as `lvs_run/family/manifest.tsv`), reports `PARTIAL`, and
compares and updates nothing. An `--only` that matches no manifest line is `CANNOT-RUN`, not a
green over an empty set. This is the loop to debug one family's switches in when the full 51 must
not be re-run for it. `--only` narrows what *runs*, not what is *checked*: the switch comparison
still covers the whole manifest, so a family iteration cannot hide a line that disagrees.

Only accept a *green* refresh: the exit statuses are `0` current/updated/partial, `1` stale, broken
or a switch disagreement, `2` cannot-run, and neither `BROKEN` nor `SWITCHES` overwrites anything.

## What this evidence is not

It is the deck and the harness on the PDK's fixtures, not on GRX930. Nothing here says the
September GDS and the routed netlist agree, or that the wrapper passes. When a real GDS and netlist
are checked, run the gate in its live mode
(`bash build/lvs_check.sh --live --layout <gds> --netlist <cdl>`), which runs the harness and judges
the single-report shape it just produced.

The port comparison is ours, not the deck's — the deck's own `check_ports` path cannot run
(`flag_missing_ports` is assigned nowhere, in any copy), which is why each entry records
`"deck_variable_defined": false` and `"checked_by": "klayout_lvs.py"`.
