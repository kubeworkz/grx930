# Enquiry to wafer.space: is a die larger than 1×1 available?

**STATUS — ANSWERED, 27 October 2026: no.** wafer.space's public MPW runs offer the four published
slot sizes and nothing larger: no bigger slot, no contiguous multi-slot block diced as a single
design, no custom large-die service. A 1×1 is **3932 × 5122 µm, 20.12 mm²**, and that is the
ceiling.

**What this changes.** The quad-core part in `quadcore_submission_scope.md` cannot be a wafer.space
part at any size they publish. It is a foundry-shuttle or private-run submission, and the enquiry
that replaces this one is [`quadcore_gf_enquiry.md`](quadcore_gf_enquiry.md) — a written size limit
and price from GlobalFoundries for a 161 mm² die, with EUROPRACTICE's publicly priced GF180MCU
entry (€913/mm²) asked in parallel. **The 1×1 vehicle is unaffected** and continues on wafer.space.

**Why the answer can be trusted without a written reply.** It reads as a search summary rather than
a message from the company, so it was checked against the two things that decide it: wafer.space's
own published terms, and this tree's copy of their tooling. They agree on every figure that
matters — four slot sizes, `--slot` as a closed enum, `check_size.py` exiting on anything else, a
1×1 die of 3932 × 5122 µm at 12.92 mm² of core, $8,000 per full slot with 1,000 dice, $1,500
chip-on-board. None of the conclusion depends on the reply's provenance.

---

## The answer, point by point

| Question asked | Answer | Checked against |
|---|---|---|
| Is any die larger than 1×1 available? | **No** — fixed at 1×1, 0.5×1, 1×0.5, 0.5×0.5; no multi-slot blocks, no single-large-die dicing, no custom runs | `precheck.py` `--slot` choices; `check_size.py`'s four branches; `AVAILABLE_SLOTS` in the template `Makefile` |
| Maximum die, price, quantity | **3932 × 5122 µm, 20.12 mm²**; $7,000–$8,000 per full slot (~$7–8/die); **1,000 dice**; chip-on-board ~$1,500 | `slot_1x1.yaml` `DIE_AREA` and `CORE_AREA` (12.92 mm²); the Run 3 campaign page |
| Would the pre-check support a larger die? | **No** — size and pad-opening checks are per-slot (`mask_<slot>.gds`), four of them | `check_size.py`; the four `mask_*.gds` files |
| Geometry / saw street | published dimensions are the **final die**, not a pitch including streets; no street width is published for multi-tile dicing | **this settles the original question 4**: for a 1×1 the outline is exactly 3932 × 5122 µm, which the template already draws. The 60 µm figure in `check_size.py` is the street *inside* a tile when it is cut into half/quarter slots — it is not a multi-tile-gap rule, and with no larger die it is moot |
| Custom pad ring / CoB | both allowed — **but only within the four slot sizes** | our own ring is what the 1×1 part already builds; note the acceptance gate is still the per-slot pad mask, so "allowed" does not move the 74-opening offset already on the precheck list |
| Alternative routes | GF directly (GlobalShuttle), other MPW brokers (MOSIS, CMP / EUROPRACTICE), or a private run | researched: see `quadcore_gf_enquiry.md` and §8 of the scope doc |

**What it does not settle:** whether GlobalFoundries will accept a 161 mm² design on a shuttle (their
terms are unpublished); whether a later wafer.space run adds larger slots (their commercial
decision); and whether a die this size yields acceptably — which is a question for whoever quotes it.

---

## Consequence

1. **The single-die quad-core is a foundry part.** The size the design needs (161 mm², 7.864 ×
   20.488 mm) is 8× the largest published slot, and it needs 320 SRAM blocks against the 80 a full
   slot holds. Nothing in the pre-check, the template or the pad-mask set has a path for it.
2. **The four-die fallback does not rescue it.** One core (5.95 mm² of cells) plus one NPU
   (8.86 mm²) is 14.81 mm² against a 12.92 mm² core, at 100 % utilisation before any memory. Four
   1×1 slots buy four single-core dies — four of the vehicle we are taping out — not four cores plus
   two accelerators. The arithmetic is in `quadcore_submission_scope.md` §8.
3. **The 1×1 vehicle's plan is unchanged.** Its slot, pad ring, price and precheck path are exactly
   what this document was already built on; the only thing lost is the option of a bigger die from
   the same supplier.

---

## The email as drafted (kept for the record)

**Sent to:** `info@wafer.space` (their contact address; the Run 3 campaign page also asks for name,
organisation, address, phone, email and the list of slot sizes wanted).
**What a useful reply would have contained:** whether a larger die exists (as a slot, as a
contiguous multi-slot block, or only on a private run), its maximum size, price basis, minimum
quantity, the run it would land on, and whether the pre-check would be extended to size/mask it.

**Subject:** Slot larger than 1×1 — available, and on which run?

Hello,

We are the GRX930 project. We are mid-flow on a 1×1 GF180MCU submission for the next available
run, and we are now scoping a second part that needs a larger die. Before we commit design work
to it we need to know whether that die size can be manufactured on a wafer.space run at all.

**The part.** Four RISC-V cores plus two systolic-array accelerators, 5 V, 5LM, no analog. On
your published Full-slot geometry it needs **7.864 × 20.488 mm** — a contiguous 2×4 block of Full
slots, 161 mm² of die and about 137 mm² of core. Its memory alone is **160 KB of 5 V SRAM**, which
against the capacity table on your technology page is roughly **320 `sram512x8` blocks against the
80 blocks — 40 KB — a full slot holds**. This is not a shrink-to-fit case: the logic alone is
~46 mm² of standard cells, 3.6× the 12.92 mm² core of a full slot, before any memory.

**Our questions, in order:**

1. Does wafer.space offer a die larger than 1×1 — as a larger slot, as a contiguous multi-slot
   block that is diced as a single design, or only on a private/custom run?
2. If it exists: what is the maximum die size, how is it priced (per mm² or per slot-unit), what
   is the minimum quantity, and which run would it land on?
3. Would the pre-check support it? Today `--slot` accepts only `1x1`, `0p5x1`, `1x0p5` and
   `0p5x0p5`, and the size and pad-opening checks are per-slot (`mask_<slot>.gds`). A larger die
   would need a size check and a pad mask issued for it.
4. Geometry, so we draw the right outline: are we correct that a Full slot is 3932 × 5122 µm and
   that the 60 µm saw street sits between slots? Tiling 2×4 without the streets gives
   7.864 × 20.488 mm; counting the streets between units gives 7.924 × 20.668 mm. Which outline
   would the design need to draw?
5. If a larger die is not available from you, is there a route you would point us to — a private
   run, a partner, another GF180 MPW — or would you be able to run one?

Two smaller ones: we build our own pad ring, so does that change any of the above; and do your
assembly options (chip-on-board, the ~1,000-die quantity) still apply at that size?

Our 1×1 vehicle is independent and continues either way. The larger part is a decision we expect
to take in the next few months, so an answer of "no" is as useful to us as a "yes" — we mainly
need to stop planning against an option that does not exist.

Thank you,

[Name] · GRX930 project · [email] · [phone] · [organisation and address]

---

## Appendix — the numbers it was asked with

| | |
|---|---|
| Process | GF180MCU, 5LM_1TM_11K, 5 V (`gf180mcu_fd_sc_mcu7t5v0`, `gf180mcu_fd_io`) |
| Die as tiled | 7.864 × 20.488 mm = 161.1 mm² (2 × 4 Full slots) |
| Core | ~137 mm² at a contiguous 2×4 tile |
| Logic cells | ~46 mm² (4 cores ~23.8, 2 accelerators ~17.7, operand RAM ~2.7, glue ~2) |
| Memory | 160 KB of 5 V `sram512x8`-equivalent (~320 blocks) — 32 KB L1, 64 KB L2, 64 KB main |
| Pad ring | our own; ~18 power and ~30 signals, CoB preferred |
| Reference point | our 1×1 vehicle measures ~28.6 k cells/mm² (370,059 instances in the 12.93 mm² core) against Run 1's best core at 22 k — we are not assuming a density that has not been demonstrated on this shuttle |

## Notes (internal, not for sending)

* The two open numbers in the original draft that a reply would have closed — the multi-tile outline
  and whether the pre-check would be extended — are both **moot**: there is no multi-tile product,
  and the pre-check is fixed to four slot masks.
* The fallback in `quadcore_submission_scope.md` §8 (a four-die module over the GRXIConnect link)
  remains technically available, at ~$32k for four slots, but it is **not this part** — it cannot
  hold a core and an accelerator on the same die. Do not describe it as the quad-core in any client
  document.
* Do not ask wafer.space for design help: they list independent consultants for that, and mixing
  the two dilutes the question.
