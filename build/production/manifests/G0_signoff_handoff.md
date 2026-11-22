# G0 signoff handoff — GRX930 test chip

**Current state:** `READY_FOR_REVIEW`; `G0_signoff.txt` is absent. This handoff is
not a signature and does not authorize one. Every reviewer name, date, result,
and signoff value below is intentionally blank.

## Manifest hash to sign

```text
15f623f5127715d47b8436bf43fa39b1c8f31a393773835c3f0ab0814d560800
```

This is the SHA-256 of `build/production/manifests/input_sha256.txt`, not of the
GDS or any single input.

## Evidence checks

Run from the repository root. The full input check requires the external design
inputs to be present in this worktree; only three of the 13 manifest entries are
tracked.

```bash
sha256sum build/production/manifests/input_sha256.txt
# expect 15f623f5127715d47b8436bf43fa39b1c8f31a393773835c3f0ab0814d560800

sha256sum -c build/production/manifests/input_sha256.txt
# expect 13 "OK" lines and exit 0

grep -E '^(status|missing|failures|manifest_sha256)=' \
  build/production/manifests/G0_status.txt
# expect READY_FOR_REVIEW, none, none, 15f623f5...
```

Reviewer evidence hashes:

| File | SHA-256 |
|---|---|
| `input_sha256.txt` | `15f623f5127715d47b8436bf43fa39b1c8f31a393773835c3f0ab0814d560800` |
| `G0_status.txt` | `99d4be37683047fe11abb1284a4cb96f71277e1c3004bf51cb31aace78879a85` |
| `g0_run.log` | `4ababf5a9551e50319c4af3dca5f62addfda30cc2dadf176c7348b893691a4b8` |
| `gds_checks.txt` | `8a725206a60088ab85199b9f38f55f57c65155c892fcee446ddd1c9d880fdda0` |
| `def_gds_checks.txt` | `d42b537a397acb238bf1b8ad99c7dfa53863d6365a5d124cdbc20152a14f9f5f` |
| `spef_extract.log` | `4f12d4825daaf0833c98c56a366f2feb7ce1e73df39d7dddf5b63f21c9f4604c` |
| `spef_readback.log` | `160c0b89eb55205f29ed0b6bdbf58f17b60257b39195d9e67437ce47c22f3b69` |
| `grx930_test_chip.spef` (external) | `f4d4b6f2ce01b9c52bf0808a295579dd8984cb4b8d82c1c64b78bcb7e91410b0` |
| `STAGE8_CLOSURE.md` | `92afb51c8bd24145087d81a6961e4db80cb8e7a1cc9dcbd2fe6bf1a020453839` |

Stage 8 is `CLOSED_WITH_RECORDED_EXCEPTION`: 125,214 annotated nets + 1,022
no-wire/<2-terminal nets = 126,236 DEF signal nets. No clock net is in the
exception class; only the `nom` RC corner was extracted.

CDL exception: the route209 evidence is **post-hoc content evidence only**. It
reproduces all 209,075 X-instance lines and the sorted X-instance set matches the
G0 CDL, but the original routed netlist, tool revision, and original
`cdl.log`/`pipeline_tap.log` remain unpinned. The design lead must explicitly
accept this exception before signoff.

## Review-row wording

These are the package's three rows, with every review field left blank. Complete
a row only after performing that review.

| Role | Review scope | Name | Date (UTC) | Result |
|---|---|---|---|---|
| Design lead | Frozen GDS/CDL/DEF/SPEF identity, 168-drop geometry, G0 status |  |  |  |
| Independent reviewer | Recompute manifest and all 13 input hashes; confirm SPEF readback |  |  |  |
| Gridworkz signatory | Confirm both reviews; fill the five fields above |  |  |  |

Suggested result wording after review:

- Design lead: `PASS` or `PASS WITH RECORDED CDL EXCEPTION`
- Independent reviewer: `PASS`
- Gridworkz signatory: `SIGNED` only after `G0_signoff.txt` is created with valid fields

Design-lead CDL exception line:

```text
Design lead: ____________________  Date (UTC): ____________________

Result: ____________________
# proposed wording: ACCEPTED_WITH_RECORDED_EXCEPTION
```

Do not fill this line unless you are the design lead accepting the documented
content-only exception.

## Five signoff fields

Only an authorized Gridworkz signatory creates `G0_signoff.txt`, after both
review rows are complete. The signature values remain blank in this handoff.

```text
gate=G0
status=SIGNED
signed_by=
signed_utc=
manifest_sha256=15f623f5127715d47b8436bf43fa39b1c8f31a393773835c3f0ab0814d560800
```

Rules:

- `signed_by` must be non-empty and contain `Gridworkz`.
- `signed_utc` must be ISO 8601 UTC.
- `status=SIGNED` only after both reviews pass.
- The manifest hash must match exactly.
- Do not edit `G0_signoff.template.txt`.

**Stop conditions:** do not sign if any input hash fails, either review row is
incomplete, the design lead has not accepted the CDL exception, or the manifest
hash does not match. This handoff does not create `G0_signoff.txt`, fill
signature fields, start LVS, or change G0 state.
