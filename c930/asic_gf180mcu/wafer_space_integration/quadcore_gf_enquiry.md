# Enquiry to GlobalFoundries: a 161 mm² GF180MCU die on a shuttle run?

**Send to — GlobalFoundries:** the GlobalShuttle MPW enquiry form,
`gf.com/about-gf/contact-us/globalshuttle-mpw-inquiries/` (reached from *Contact us → GlobalShuttle™
MPW support*; existing customers can also use **GF Connect**, `portal.myglobalfoundries.com`).
There is **no MPW email address** — the form is the published route. Fields, read 27 Oct 2026:
**required** = email address, country, question text, privacy-policy consent; expected = company,
company website, first and last name, phone; plus a “My question is related to” box and an invisible
reCAPTCHA. Country is the one field that cannot be inferred from the project, and it also drives
export screening, so it is supplied by the sender rather than assumed.

**Send to — EUROPRACTICE:** **not an email address, and not an open enquiry.** Their
GlobalFoundries access runs through **Fraunhofer IIS**: the `NDA_Request_Form` returned in **.docx**
to **`virtual-asic@iis.fraunhofer.de`**, plus their questionnaire, and *“Global Foundries only
concludes agreements with companies and universities/Research institutes, NOT with individuals”* —
the NDA must carry legally binding signatures from an official representative. Contact for the
GlobalFoundries technologies: Syed Shahnawaz, `virtual-asic@iis.fraunhofer.de`,
+49 9131 776 4425. A size/price question can be asked by email first; the **order** is NDA-gated and
entity-only, so it is a step the project's authorised signatory has to take, not an agent.

**Why now:** wafer.space answered “no” on 27 October 2026 — their catalogue stops at 1×1
(20.12 mm²), with no multi-slot block and no custom large-die service
([`quadcore_slot_enquiry.md`](quadcore_slot_enquiry.md)). The part is 161 mm², so a foundry shuttle
or a private run are the only remaining routes.

**What a useful reply contains:** a written maximum design area for GF180MCU shuttle runs; whether
7.864 × 20.488 mm fits the reticle field; the price basis and a figure for 161 mm²; the dice
included; the next 180 nm tapeout dates and deadlines; the BEOL stack and accepted PDK revision;
and, if a single die this size is refused, the private-run terms.

---

## Sent — 27 October 2026

Submitted through GF's GlobalShuttle MPW form
(`gf.com/about-gf/contact-us/globalshuttle-mpw-inquiries/`); the page returned *“Thanks for
contacting us! We will be in touch with you shortly.”* What it carried:

| Field | Value |
|---|---|
| Company | Gridworkz |
| Company website | `https://github.com/kubeworkz` — the field is **enforced**: the first submit was refused with “This field is required.” although the input carries no `required` attribute. gridworkz.com does not resolve, so the account page went in its place |
| First name | Dave |
| Email | dave@gridworkz.com |
| Country | Canada |
| Phone | left empty (optional) |
| My question is related to | GlobalShuttle MPW — GF180MCU (180 nm): design-area limit and price for a 161 mm² die |
| Consent | GF's privacy policy, ticked to submit |

**The address on the form can receive a reply.** `gridworkz.com` publishes Google Workspace MX
records (`aspmx.l.google.com` and the four alternates) and a Google site-verification TXT, read
27 Oct 2026, even though it serves no website — so a reply from GF and one from Fraunhofer IIS both
land in `dave@gridworkz.com`, which is what makes “watch for the replies” a real step rather than a
hope. It also confirms the Gmail connection is the right one for this project.

**The form caps the question at 700 characters.** The full seven-question enquiry below is 2,653
characters and the field's own `maxlength` would have refused it, so what was submitted is a
671-character version, verbatim:

> GF180MCU: is a 161 mm² single die available on a GlobalShuttle run?
>
> We are designing a four-core RISC-V SoC plus two systolic-array accelerators on the open GF180MCU
> PDK (5LM, 1.8/3.3/5 V). With the memories as gf180mcu_fd_ip_sram macros the die is 7.864 ×
> 20.488 mm, 161 mm².
>
> What is the maximum single-design area on a shuttle run, and does 7.864 × 20.488 mm fit the reticle
> field? How is a design this size priced, and how many dice come with it? If it needs a private run,
> what are the mask NRE and minimum wafer terms?
>
> Full design summary and remaining questions on request. Our 1×1 vehicle is in a wafer.space pooled
> run at your Singapore site and is unaffected.

The email below is therefore the **detailed version**, to send only if GF replies asking for it. It
carries three things the short form could not: the BEOL-stack and PDK-revision question (5LM vs
1P6M), the signoff-deck question, and the explicit private-run terms.

---

## The email

**Subject:** GF180MCU: is a 161 mm² design (7.864 × 20.488 mm) available on a GlobalShuttle run?

Hello,

We are the GRX930 project and we are designing a four-core RISC-V SoC with two systolic-array
accelerators on GF180MCU. Our current 1×1 vehicle is in a wafer.space pooled run, fabricated at
your Singapore site, and it continues there. This enquiry is about a second, larger part: before we
commit design work to it we need to know whether a die of this size can be built on a shuttle run at
all.

**The part.** Four RV64IMAC cores, two 8×8 systolic-array accelerators, a 64 KB shared L2 and
**160 KB of 5 V SRAM** in total, on the 5-metal stack, 1.8 / 3.3 / 5 V, no analog and no NVM.
Measured on our own GF180 runs, one core is 5.95 mm² of standard cells and one accelerator
8.86 mm², so the logic is ~46 mm². With the memories as `gf180mcu_fd_ip_sram` macros the die comes
to **7.864 × 20.488 mm, 161 mm²**, with a ~137 mm² core. We design our own pad ring (~18 power,
~30 signal pads) and prefer chip-on-board.

**Our questions, in order:**

1. Is GF180MCU (180 nm) currently on the GlobalShuttle schedule? Which months, and what is the
   submission deadline before each?
2. What is the maximum single-design area on a shuttle run, and can a 161 mm² die be accepted as one
   design — or does a die this size require a private/custom run?
3. Does 7.864 × 20.488 mm fit the reticle field for this process, and are there minimum or maximum
   die dimensions we should be designing to?
4. How is a design this size priced — per mm², per block, per die — and what would 161 mm² cost?
   What NRE or mask share applies, and how many dice come with it? Your MPW description mentions
   samples up to 100 dice as part of the base fee; does that hold for a design at this size?
5. Which PDK revision and BEOL stack are accepted? We build against the open GF180MCU PDK on the
   **5-metal (5LM)** option with `gf180mcu_fd_sc_mcu7t5v0` cells and `gf180mcu_fd_ip_sram` macros.
   Please confirm 5LM is offered on the shuttle — and if the offering is 1P6M rather than 5LM, say
   so, because our flow, PDN and antenna rules follow the stack.
6. Do you accept the open PDK's DRC / LVS / antenna decks for signoff, or is a specific GF deck
   required? Are there pad-ring, seal-ring and scribe rules specific to a die this size?
7. If a single 161 mm² die is not available: what are the private-run terms — mask NRE, minimum
   wafer count, wafer price and lead time?

The design is not frozen — the memory configuration is still open — so what we need at this stage
is the size limit and the price basis, not a firm quotation. An answer of “not on a shuttle, private
run only” is as useful to us as a yes: it decides whether we proceed with this die or restructure
the part.

Thank you,

[Name]
GRX930 project
[email] · [phone] · [organisation and address]

---

## Second recipient — EUROPRACTICE / Fraunhofer IIS

**Status: SENT — 27 October 2026, from `dave@gridworkz.com`.** Sent through the Gmail compose window
in the browser session. Note the route, because it is not the intended one: the project still has
**no Freebuff mail app connected**, so this went out through the mailbox itself rather than through
an integration. Receipts: Gmail's “Message sent” confirmation with the Undo affordance, and the item
present in the **Sent** label under the subject below, addressed to `virtual-asic@iis.fraunhofer.de`.
As sent: **20 lines, 1,873 characters, five numbered questions**, the draft's markdown markers
stripped for plain text. Recipient:
**Syed Shahnawaz, `virtual-asic@iis.fraunhofer.de`, +49 9131 776 4425** (listed on EUROPRACTICE's
contact page for GLOBALFOUNDRIES; Fraunhofer IIS, Am Wolfsmantel 33, 91058 Erlangen).

**What sending this does not do:** it does not start the NDA. GF only contracts with companies and
research institutes, and the NDA must carry a legally binding signature from an authorised
representative — the `NDA_Request_Form` and the questionnaire are the project's own acts, and the
email says so in as many words. Nothing else was sent, and no documents were attached.

**The NDA pack is SENT — 27 October 2026, from `dave@gridworkz.com`.** The two documents the order is
gated on — EUROPRACTICE's `NDA_Request_Form` (Word) and its questionnaire (a five-slide project deck) —
are published as links on that same access page and were filled in [`nda_pack/`](nda_pack/): the
entity's own details included — signatory **Dave Cook, Owner**, 1931 Norris Ave., Fort Erie, Ontario
L2A5M4, Canada, +1 289-303-7651. One email went to **Syed Shahnawaz,
`virtual-asic@iis.fraunhofer.de`** with both files attached — the form 24,187 B, the deck 3,648,739 B —
subject `GF180MCU via EUROPRACTICE — NDA request form and questionnaire (GRX930)`, sent
27 October 2026 16:47:47 −0700, message id `1a17fc34b4f1a94c`. It went through the connected Gmail
integration, the draft having been assembled in the mailbox itself (the integration's attachment field
accepts only stored file references, never a local path). The **Sent copy was then verified through the
API: both attachments were downloaded from the sent message and hashed to the prepared files'
digests** (`1b918917…` for the form, `8b7ab88d…` for the deck), so the bytes delivered are the prepared
documents. The one act that remains is the entity's own: the signature (which goes on the NDA itself,
not on this form). `nda_pack/README.md` carries the full receipt table.

**Subject:** GF180MCU via EUROPRACTICE — maximum die size and price basis for a 161 mm² design

Dear Mr Shahnawaz,

We are the GRX930 project. We are designing a four-core RISC-V SoC with two systolic-array
accelerators on GF180MCU, against the open GF180MCU PDK (5-metal, 1.8/3.3/5 V,
`gf180mcu_fd_sc_mcu7t5v0` cells, `gf180mcu_fd_ip_sram` macros). Our current 1×1 vehicle is in a
wafer.space pooled run; this enquiry is about a second, larger part.

Before committing design work, we need to know whether a design of this size can be ordered through
EUROPRACTICE at all. Your 2026 price list prices GF180MCU by area (€913/mm², €830 discounted, 6 mm²
minimum billed), but we could not find a maximum die size or a maximum block count anywhere in the
public material.

1. What is the largest single die accepted on a GF180MCU MPW run? A single design of
   **7.864 × 20.488 mm, 161 mm²** is the size this part needs.
2. Does 7.864 × 20.488 mm fit the reticle field for the process, and is that aspect ratio acceptable?
3. If it is accepted, how is it quoted — as N contiguous blocks, at the per-mm² rate, or by separate
   quotation? What would 161 mm² cost, and how many dice come with it?
4. Which PDK revision and BEOL stack does the GF180MCU offering use — 5LM or 1P6M? Our flow, PDN and
   antenna rules follow the stack, so we would like to confirm it before further work. Do you accept
   the open PDK's DRC / LVS / antenna decks for signoff?
5. What are the next GF180MCU registration dates and their GDS deadlines?

We understand that the order itself requires an NDA signed by an authorised representative of our
company, and we will start that process once the size question is settled — we are not asking you to
pre-empt it, only whether this die is possible and how it would be priced.

The design is not frozen (the memory configuration is still open), so the size limit and price basis
are what we need, not a firm quotation.

Kind regards,
Dave
Gridworkz
dave@gridworkz.com

**Send this only as the question.** The NDA, the questionnaire and the purchase order are the
project's own acts — GF only contracts with companies and research institutes, and the NDA must
carry a legally binding signature from an authorised representative.

---

## Appendix — the numbers, if they ask

| | |
|---|---|
| Process | GF180MCU, 180 nm, 5LM, 1.8 / 3.3 / 5 V, `gf180mcu_fd_sc_mcu7t5v0` |
| Die | 7.864 × 20.488 mm = 161.1 mm², one design, no die stitching |
| Core | ~137 mm² (die − 884 µm per axis, the 1×1 template's own ring allowance) |
| Logic | ~46 mm² of cells: 4 cores 23.8, 2 accelerators 17.7, operand RAM 2.7, glue ~2 |
| Memory | 160 KB of 5 V SRAM: 320 `sram512x8m8wm1` blocks (L1 32 KB, L2 64 KB, main 64 KB) |
| Pad ring | ours; ~18 power and ~30 signal pads |
| Assembly | chip-on-board preferred |
| Timing basis | 40 ns (25 MHz) target — the period the 1×1 vehicle's data paths already close at |
| Reference | 1×1 vehicle: 370,059 instances in a 12.93 mm² core, ~28.6 k cells/mm², precheck-clean path in progress |

## Notes (internal, not for sending)

* **5LM is not 1P6M.** The PDK's design manual defines 5LM as five metal layers and lists 1P6M
  separately as a BEOL option; the reply to the wafer.space enquiry repeated the conflation
  (“5LM_1TM_11K”, “1P6M”). Ask which one the shuttle offers rather than assuming they are the same
  thing — the flow, the PDN straps and the antenna rules all follow the stack.
* **Ask EUROPRACTICE in parallel — but expect a gate.** Their 2026 price list prices GF180MCU by
  area — **€913/mm²** standard, **€830/mm²** discounted, **6 mm² minimum billed** — which makes
  161 mm² **≈€147k / ≈€134k** *if accepted*. Two GF180MCU registration dates fall in 2026. Their
  maximum die size is not published either, so the same question goes to both. The difference that
  matters commercially: at EUROPRACTICE the **block size is fixed per technology** on their
  technology pages (12–25 mm² for the GF processes listed), which is a second place a 161 mm² die
  can fail — ask it explicitly rather than inferring from the per-mm² rate.
* **The order is not the enquiry.** EUROPRACTICE's GF route needs a signed NDA from an authorised
  representative of a company or research institute, so an agent cannot take it any further than
  the first question. Keep that distinction in the record: question now, NDA when the part is a
  decision.
* **Do not ask for design support.** GF lists MPW support as scheduling, submissions, technical
  requirements and documentation; a design-services question will slow the reply.
* **A “no” is a product decision, not a delay.** The private-run fallback is a ~$100k mask set plus
  a wafer lot (25 wafers is the usual convention, ~$1.5k each) — an order of $150k–$250k before
  backend. The four-die module on wafer.space is ~$32k but cannot carry the accelerators
  (`quadcore_submission_scope.md` §8). If GF says no, the choice is between paying that and
  changing the part — do not present it as a matter of waiting for a bigger slot.
* **Send both enquiries the same day** so the two answers are comparable, and record each reply in
  the section below rather than in a chat log.

## Replies

*(GF enquiry sent 27 Oct 2026; the NDA pack to Fraunhofer IIS went out the same day — awaiting reply. Date-stamp each reply here and fold the numbers into `quadcore_submission_scope.md`
§8. The questions to be answered, so a reply can be scored rather than filed: **maximum design area**
for GF180MCU shuttle runs; whether **7.864 × 20.488 mm** fits the reticle field; the **price basis**
and a figure for 161 mm²; the **dice included**; the **next tapeout dates**; the accepted **BEOL stack
and PDK revision**; and, if refused, the **private-run terms**.)*
