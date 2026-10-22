# First green LVS in this repo — the PDK's own `sample_nfet_05v0` fixture

Captured 2026-10-17 from this box, image `ghcr.io/efabless/openlane2:2.3.10`, deck
`c930/asic_gf180mcu/libs.tech/klayout/tech/lvs/gf180mcu.lvs`
(sha256 `00019ed0a7f434fc9ead466be75c07cbaed4bf5de698446d6e3fafd43ac7cc59`).

```
topcell  sample_nfet_05v0
devices  MATCH    extracted 99 instances, schematic 104
ports    PASS     schematic 295 ports, layout 295 pins, missing none
verdict  MATCH
```

The deck's own words, last lines of `klayout.log`:

```
LVS Total Run Time 20.960274 seconds
INFO : Congratulations! Netlists match.
```

## Reproduce

```sh
cd <repo root>
bash c930/asic_gf180mcu/tools/klayout_lvs.sh
```

Writes `c930/asic_gf180mcu/lvs_runs/nfet_05v0/` (gitignored): `verdict.json`, `klayout.log`,
`extracted.cir`, `report.lvsdb`. The four-arm discrimination test is
`bash c930/asic_gf180mcu/tools/klayout_lvs_selftest.sh` — 16 assertions, green here.

## What the two engines said, and why they disagree on the device count

* **Devices: match.** The deck compared the extracted netlist against
  `lvs/testing/unit/mos_devices/netlist/nfet_05v0.cdl` with `combine=true`, the setting the PDK's
  own per-device config uses for this device.
* **99 extracted instances vs 104 in the schematic** is not a discrepancy: `combine` merges
  parallel fingers of the same device, so the extracted netlist carries fewer, wider devices.
  The instance counts are recorded, not asserted equal — the deck's verdict is the authority.
* **Ports: pass, and this check is ours.** The deck's own port check cannot run at all: its
  comparison section ends with `result &= flag_missing_ports if CHECK_PORTS`, and
  `flag_missing_ports` is assigned nowhere — not in this deck revision, not in any
  `rule_decks/*.lvs`, and not at upstream `main` (checked 2026-10-17; commits 9ba05b0 and
  355b9ee added the reference, 2026-07-17). `CHECK_PORTS` defaults to *true* and `run_lvs.py` has
  no `--check_ports` option (0 mentions, against 5 for `top_lvl_pins`), so the PDK's documented
  path dies with `undefined local variable 'flag_missing_ports'` for every design. There is no
  "right" deck/runner pair to find: the check has never executed in any released copy.
  `tools/klayout_lvs.py` runs the deck with `check_ports=false` and requires every schematic
  top-level port to appear among the layout's top-level pins.
* **295 ports on the schematic side** is the fixture's own shape: its `.SUBCKT` declares every
  labelled internal net as a pin, and `top_lvl_pins=true` makes the deck emit the same 295 on the
  layout side. All 295 match.

## A second fixture, to show it is not a one-off

The PMOS fixture matches too, but only with the switch its own PDK config asks for
(`implicit_connect: true` beside `combine: true` in `mos_devices/config/default.yaml`):

```
bash c930/asic_gf180mcu/tools/klayout_lvs.sh --fixture pfet_05v0 --implicit-connect
  devices  MATCH    extracted 100 instances, schematic 105
  ports    PASS     schematic 298 ports, layout 298 pins, missing none
  verdict  MATCH
```

With `combine` alone this pair reports a mismatch (measured 2026-10-17): without implicit
connections each finger's gate/tap stays its own net, so the 249 extracted devices never join up.
That is a deck setting, not a layout defect — recorded here so a future reader does not read it as
one. Verdict: `pfet_05v0.verdict.json` / `.txt`.

## What makes this green credible

`klayout_lvs_selftest.sh` runs the same pair four ways and requires the verdict to move:

| arm | change | required result | measured |
|---|---|---|---|
| A | none | match | exit 0, verdict match |
| B | one MOSFET statement deleted from the schematic | mismatch | exit 1, devices mismatch |
| C | one top-level port renamed (`I1_default_G` → `I1_default_GX`) | mismatch on **ports**, devices still match | exit 1, `missing_in_layout: ["I1_default_GX"]`, devices match |
| D | layout path does not exist | setup error, no verdict | exit 2, no `verdict.json` |

Arm C is the reason the port check had to be reimplemented rather than skipped: with the deck's
dead check and `--no-port-check`, a renamed port is invisible.

## What this does not prove

* It is a **device fixture**, not GRX930. Nothing here says the September GDS and
  `build/grx930_test_chip_routed.v` agree, or that the wrapper (`tpl02`) passes.
* The port comparison is **ours**, written because the deck's is absent. It requires schematic
  ports to exist as layout pins; it does not check port *direction* or that a layout pin unused by
  the schematic is an error (with `top_lvl_pins` every labelled net becomes a pin, so extra pins
  are expected).
* The vendored deck is **unmodified**. The PDK tree is not tracked in this repo, so no patch to it
  would survive a re-install; the workaround lives in `tools/`, and `verdict.json` records
  `"deck_variable_defined": false` so a future green cannot silently claim the deck's own check ran.
* `pmap` is shimmed: the deck's logger calls it for a memory line and dies on `nil.strip` without
  it. That is a logging dependency, not a measurement.
