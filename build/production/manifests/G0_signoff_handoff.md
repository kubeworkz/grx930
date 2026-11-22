# G0 signoff handoff — GRX930 test chip

**Current state:** `G0_signoff.txt` is present and its five fields verify.
The design-lead CDL exception is recorded; the independent review is signed by
Michele Cook. This handoff is not itself a signature and does not authorize
one.

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
# current working tree: READY_FOR_REVIEW, none, none, 15f623f5...
```

Reviewer evidence hashes:

| File | SHA-256 |
|---|---|
| `input_sha256.txt` | `15f623f5127715d47b8436bf43fa39b1c8f31a393773835c3f0ab0814d560800` |
| `G0_status.txt` (READY_FOR_REVIEW snapshot) | `99d4be37683047fe11abb1284a4cb96f71277e1c3004bf51cb31aace78879a85` |
| `G0_signoff.txt` (present) | `5eb984defb38c57f55bb46d79d899ca523312ce6d7b646c1465b4446ec2f0840` |
| `g0_run.log` | `4ababf5a9551e50319c4af3dca5f62addfda30cc2dadf176c7348b893691a4b8` |
| `gds_checks.txt` | `8a725206a60088ab85199b9f38f55f57c65155c892fcee446ddd1c9d880fdda0` |
| `def_gds_checks.txt` | `d42b537a397acb238bf1b8ad99c7dfa53863d6365a5d124cdbc20152a14f9f5f` |
| `spef_extract.log` | `4f12d4825daaf0833c98c56a366f2feb7ce1e73df39d7dddf5b63f21c9f4604c` |
| `spef_readback.log` | `160c0b89eb55205f29ed0b6bdbf58f17b60257b39195d9e67437ce47c22f3b69` |
| `grx930_test_chip.spef` (external) | `f4d4b6f2ce01b9c52bf0808a295579dd8984cb4b8d82c1c64b78bcb7e91410b0` |
| `STAGE8_CLOSURE.md` | `92afb51c8bd24145087d81a6961e4db80cb8e7a1cc9dcbd2fe6bf1a020453839` |

`G0_status.txt` now reports `status=READY_FOR_REVIEW` and `owner=Gridworkz`; its
current working-tree hash is
`a05a7924b6a397144ff81456462f1f55f1a248bcdd425ea7c1b4365b2317dd50`. The table
records the original review snapshot.

Stage 8 is `CLOSED_WITH_RECORDED_EXCEPTION`: 125,214 annotated nets + 1,022
no-wire/<2-terminal nets = 126,236 DEF signal nets. No clock net is in the
exception class; only the `nom` RC corner was extracted.

CDL exception: the route209 evidence is **post-hoc content evidence only**. It
reproduces all 209,075 X-instance lines and the sorted X-instance set matches the
G0 CDL, but the original routed netlist, tool revision, and original
`cdl.log`/`pipeline_tap.log` remain unpinned. The design lead must explicitly
accept this exception before signoff.

## Review rows

The design lead, independent reviewer, and verified signatory are recorded
below.

| Role | Review scope | Name | Date (UTC) | Result |
|---|---|---|---|---|
| Design lead | Frozen GDS/CDL/DEF/SPEF identity, 168-drop geometry, G0 status | Gridworkz | 2026-11-21 | PASS WITH RECORDED CDL EXCEPTION |
| Independent reviewer | Recompute manifest and all 13 input hashes; confirm SPEF readback | Michele Cook | — | SIGNED — Michele Cook |
| Gridworkz signatory | Confirm both reviews; fill the five fields above | Dave Cook | 2026-11-21 | SIGNED — verified against `G0_signoff.txt` |

Recorded review results:

- Design lead: Gridworkz
- Independent reviewer: `SIGNED` — Michele Cook
- Gridworkz signatory: `SIGNED` — verified against `G0_signoff.txt`

Design-lead CDL exception line:

```text
Design lead: Gridworkz  Date (UTC): 2026-11-21T21:39:35Z

Result: ACCEPTED_WITH_RECORDED_EXCEPTION
```

The design lead recorded this acceptance of the documented content-only
exception.

## Five signoff fields

`G0_signoff.txt` is present and field-verified. The values below match it. The
design-lead CDL exception is recorded above.

```text
gate=G0
status=SIGNED
signed_by=Dave Cook, Founder, Gridworkz
signed_utc=2026-11-21T21:39:35Z
manifest_sha256=15f623f5127715d47b8436bf43fa39b1c8f31a393773835c3f0ab0814d560800
```

Rules:

- `signed_by` must be non-empty and contain `Gridworkz`.
- `signed_utc` must be ISO 8601 UTC.
- `status=SIGNED` only after both reviews pass.
- The manifest hash must match exactly.
- Do not edit `G0_signoff.template.txt`.

## Creation procedure (authorized signatory only)

Only an authorized Gridworkz signatory performs this procedure, after both
review rows are complete and the design lead has accepted the CDL exception.
This handoff does not create `G0_signoff.txt`.

1. Copy the template; do not edit the template itself:

   ```bash
   cp build/production/manifests/G0_signoff.template.txt \
      build/production/manifests/G0_signoff.txt
   ```

2. Fill the five fields exactly. The verified values are shown here; the
   authorized signatory supplies them in the copied file:

   ```text
   gate=G0
   status=SIGNED
   signed_by=Dave Cook, Founder, Gridworkz
   signed_utc=2026-11-21T21:39:35Z
   manifest_sha256=15f623f5127715d47b8436bf43fa39b1c8f31a393773835c3f0ab0814d560800
   ```

3. Verify the copied file before treating G0 as signed:

   ```bash
   test -f build/production/manifests/G0_signoff.txt
   grep -qx 'gate=G0' build/production/manifests/G0_signoff.txt
   grep -Eq '^signed_by=.*Gridworkz' build/production/manifests/G0_signoff.txt
   grep -Eq '^signed_utc=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
     build/production/manifests/G0_signoff.txt
   grep -qx 'manifest_sha256=15f623f5127715d47b8436bf43fa39b1c8f31a393773835c3f0ab0814d560800' \
     build/production/manifests/G0_signoff.txt
   ```

4. Do not alter `G0_status.txt`, the frozen inputs, or the template. The
   signatory's file is the signature; this handoff is not.

**Gate status:** `G0_signoff.txt` is verified; the design-lead review and CDL
exception are recorded. This handoff does not create `G0_signoff.txt`, fill the
design-lead signature fields, start LVS, or change G0 state.
