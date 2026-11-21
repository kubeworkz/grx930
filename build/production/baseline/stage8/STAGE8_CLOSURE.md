# Stage 8 — RCX/SPEF closure record

**Status: CLOSED_WITH_RECORDED_EXCEPTION.** Nominal-corner SPEF extraction and
validation are complete. This record does **not** sign G0: `G0_signoff.txt`
remains absent, G2 remains blocked, and no LVS was started.

- Closed: 2026-11-21
- Design: `grx930_test_chip`
- Corner: `nom` (GF180MCU OpenRCX nominal)
- Closure owner: physical verification lead (unassigned; record only, not a G0 signature)

## Inputs

| Item | Value |
|---|---|
| OpenROAD | `dcf36133a369abc8f3c5e5738cd4d82e4903c0e0` |
| Image | `ghcr.io/wafer-space/gf180mcu-precheck:104d9ccbc0d3` |
| Database | `build/lvs_chip/eco_drop_2x2/stage6/eco_routed.odb`, 206,880,759 bytes, SHA-256 `5290f82150c00d321e9650cdbfc903fe331f29167dfbc52a2e060ec16ff52772` |
| RCX rules | `/workspace/gf180mcu/gf180mcuD/libs.tech/librelane/rules.openrcx.gf180mcuD.nom`, 31,291 bytes, SHA-256 `d83a04ea28af9b74a097fb479bbab9ed52859a1e3428b33d3151cb5afae62ddf` |

Successful extraction command:

```tcl
read_db /work/build/lvs_chip/eco_drop_2x2/stage6/eco_routed.odb
extract_parasitics -ext_model_file /workspace/gf180mcu/gf180mcuD/libs.tech/librelane/rules.openrcx.gf180mcuD.nom
write_spef /work/build/production/final/grx930_test_chip.spef
```

`define_process_corner -ext_model_index 0 <file>` alone leaves the model filename
empty in this build (`RCX-0468`); the single-corner `-ext_model_file` form loads
the same model and defines `MinMax0`. This is the command recorded in the G0
package. Extraction ended `RCX_DONE` with exit 0: 126,239 nets extracted, 728,529
rsegs/caps, 1,488,085 coupling caps, 126,236 nets finished.

## Output and corner identity

| Artifact | Value |
|---|---|
| SPEF | `build/production/final/grx930_test_chip.spef`, 188,709,802 bytes, SHA-256 `f4d4b6f2ce01b9c52bf0808a295579dd8984cb4b8d82c1c64b78bcb7e91410b0` |
| Corner sidecar | `build/production/final/grx930_test_chip.spef.corner`, SHA-256 `f91d1045e8f1ad94a70803d6ff6027a46fa28d1e7510f56a751bf27b5a64936c` |
| Clock subset | `build/production/sta/grx930_test_chip.clock_subset.spef`, 13,260,051 bytes, SHA-256 `df66552d35a1dfd3f8b091ec57f15051eecb8b9fddc7bef03ee81a5193504af5` |

The sidecar records `corner=nom`, the SPEF hash, the RCX model and its hash, the
OpenROAD commit, and the extraction date. It is the corner-name record required
by the Stage 8 plan.

## Coverage and the accepted exception

| Metric | Count |
|---|---:|
| DEF signal nets | 126,236 |
| Nets with fewer than two terminals and no wire | 1,022 |
| SPEF `*D_NET` records | 125,214 |
| Clock nets | 1 |
| Clock nets in the no-wire/<2-terminal class | 0 |

Arithmetic: `125,214 + 1,022 = 126,236`.

**Disposition: the 1,022-net coverage difference is accepted for Stage 8
closure as a recorded exception.** The audit found every one is a non-clock
signal net with no wire object and fewer than two terminals. Such a net has no
wire geometry from which OpenRCX can form a SPEF RC network; it is excluded by
construction, not by an extraction omission. This is a technical coverage
exception only. It is not an LVS/DRC waiver and does not alter G0, G2, or any
signoff requirement.

Evidence: `build/production/sta/stage8_coverage_audit.log` reports
`SIGNAL_NETS=126236 NOWIRE_LT2=1022 CLOCK_NETS=1 NOWIRE_CLOCKS=0` and
`COVERAGE_AUDIT=PASS`.

## Clock-specific annotation

The only clock net, `i_clk`, has one port driver and 33,856 loads. It is present
in the delivered SPEF as `*D_NET *1 68.7184` and is annotated after readback:

```text
Net i_clk
 Pin capacitance: 111.06
 Wire capacitance: 68.71
 Total capacitance: 179.77
 Number of drivers: 1
 Number of loads: 33856
 Number of pins: 33857
SPEF_D_NET_i_clk_PF=68.7184
CLOCK_NETS_IN_DB=1
CLOCK_ANNOTATION=PASS
```

`read_spef` reports 0 unannotated drivers and 0 partially unannotated drivers.
That driver-based report does not by itself name a top-level input-port clock, so
the `report_net i_clk` wire capacitance is the clock-specific evidence. A
clock-only `write_spef -nets {i_clk}` selection contains 227,050 `*CAP` entries
and 65,248 `*RES` entries, repeating the full SPEF's `68.7184` pF total.

## diff_spef and reproducibility

The `diff_spef` Tcl wrapper in this build ignores `-r_res`, `-r_cap`,
`-r_cc_cap`, and `-r_conn`; it tests an undefined `-over` flag instead. The
value-enabled comparison was therefore invoked directly:

```tcl
rcx::diff_spef /work/build/production/final/grx930_test_chip.spef 1 1 1 1 -1 -1
```

The call returned 0 and emitted no numeric-difference lines. Its only warnings
were the expected 1,022 nets absent from the SPEF and 236,696 tapcell instances
(`TAP_TAPCELL_ROW_*`) with no signal-net SPEF entry. No `diff_spef.out` file was
emitted by this build; the run output is captured in
`build/production/sta/spef_diff_values.log`.

As an independent check, the same extraction command was run again and a full
SPEF was written. The delivered and re-extracted files are the same size
(188,709,802 bytes), have the same 125,214 `*D_NET` records, and are
**byte-identical after excluding the `*DATE` header line**:

```text
delivered_no_date = e0e3f6a6d0fdab2c67bdb80851275acd2c394c8f27707d169dc8cee39a22a43f
reextract_no_date = e0e3f6a6d0fdab2c67bdb80851275acd2c394c8f27707d169dc8cee39a22a43f
SPEF_REPRODUCIBLE = PASS
```

This is stronger than a net-count check: it confirms the delivered RC values,
connectivity, names, and net membership reproduce exactly.

## Gate disposition

| Stage 8 gate item | Result | Basis |
|---|---|---|
| SPEF net count equals DEF net count | **PASS WITH RECORDED EXCEPTION** | 125,214 annotated + 1,022 no-wire/<2-terminal = 126,236 |
| No unannotated clock nets | **PASS** | `i_clk` wire capacitance 68.71 pF; subset has 227,050 CAP / 65,248 RES entries |
| Corner files exist | **PASS for `nom`** | `grx930_test_chip.spef.corner` names `corner=nom` |
| `read_spef` / `diff_spef` succeeds | **PASS** | 0 unannotated and 0 partial drivers; value-enabled diff rc 0; byte-identical re-extraction |

**Limitations.** Only the `nom` SPEF was produced. The plan makes `min` and `max`
SPEFs conditional on the signoff corners requiring them; no such requirement is
recorded here, and this closure does not claim min/max coverage. The
`diff_spef` wrapper bug means future runs must use the direct `rcx::diff_spef`
form with the value flags. The 236,696 instance warnings are the physical tapcell
population, not missing signal nets.

## Evidence hashes

| Artifact | SHA-256 |
|---|---|
| Delivered SPEF | `f4d4b6f2ce01b9c52bf0808a295579dd8984cb4b8d82c1c64b78bcb7e91410b0` |
| Corner sidecar | `f91d1045e8f1ad94a70803d6ff6027a46fa28d1e7510f56a751bf27b5a64936c` |
| Clock subset | `df66552d35a1dfd3f8b091ec57f15051eecb8b9fddc7bef03ee81a5193504af5` |
| Clock annotation log | `59a940e6023d9706cb73635001ac5a8a19857be910edb2e5fdc532e7580fe76b` |
| Coverage audit log | `4747b58bf32b987a5a2e1b6c7fa7e0978243acf13f05277d2121209ea299fe0f` |
| Value-enabled diff log | `4c538801a07b4fe113e4b2ac55575c1c260950a21e90e3c156604a894c6f0a52` |
| Re-extraction log | `b34c08543bb6972cfc70a9dc2e288dff12885f96612957c4b991ffc37bbd3902` |
| G0-frozen database | `5290f82150c00d321e9650cdbfc903fe331f29167dfbc52a2e060ec16ff52772` |
| `nom` RCX model | `d83a04ea28af9b74a097fb479bbab9ed52859a1e3428b33d3151cb5afae62ddf` |

## Signoff boundary

`build/production/manifests/G0_signoff.txt` is absent. G0 remains
`READY_FOR_REVIEW`, G2 remains blocked, and no LVS was started. This closure
record is evidence for review; it is not a G0 signature or a production release.
