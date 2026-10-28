# Fraunhofer IIS / EUROPRACTICE NDA pack — prepared and sent (27 October 2026)

The order route in [`quadcore_gf_enquiry.md`](../quadcore_gf_enquiry.md) is NDA-gated, and the NDA is
requested with **two documents sent to `virtual-asic@iis.fraunhofer.de`**:

* the **`NDA_Request_Form`** (Word, .docx), and
* the **questionnaire** — which is not a form at all but a five-slide project deck, `Template_UPP`.

Both are published by EUROPRACTICE's *GlobalFoundries: Access and Contacts* page
(<https://europractice-ic.com/technologies/asics/globalfoundries/access-contacts/>), hidden behind the
two instruction lines — *"Fill the NDA_Request_Form and send it in Word format (.docx) to
virtual-asic@iis.fraunhofer.de"* and *"Fill in this questionnaire and send it to
virtual-asic@iis.fraunhofer.de"* — where `NDA_Request_Form` and `this questionnaire` are hyperlinks.
Read 27 Oct 2026:

| file (as published) | sha256 |
|---|---|
| `NDA_Request_Form_GF_Rev2.0-1.docx` — <https://europractice-ic.com/wp-content/uploads/2019/11/NDA_Request_Form_GF_Rev2.0-1.docx> | `4e3631464c2c57453c8d2e298a6174ed0caceaa2b3a60d59319d0487665be507` |
| `GF_Template_PDK_request.pptx` — <https://europractice-ic.com/wp-content/uploads/2023/09/GF_Template_PDK_request.pptx> | `98ad19fbda678702b69c9041d802bb4d2a05c421aa8995b6e30a998d1c7627b0` |

This directory holds the pristine originals, the two prepared copies and the builder that produces
them from the record.

| file | role |
|---|---|
| `NDA_Request_Form_GF_Rev2.0-1.docx` | the form exactly as published (kept for audit and for rebuilding) |
| `GF_Template_PDK_request.pptx` | the questionnaire exactly as published |
| `NDA_Request_Form_GF_Rev2.0-1_prepared.docx` | **the form that was returned** — all 19 text fields filled, the two boxes this order answers ticked |
| `GF_Template_PDK_request_prepared.pptx` | **the questionnaire that was returned** — five slides filled |
| `fill_pack.py` | builds both prepared files: `python fill_pack.py` (no dependencies; edits the Office XML parts and rewrites each zip entry for entry, aborting on the first unexpected anchor) |

## Sent — 27 October 2026

The send is done. One email to **Syed Shahnawaz, `virtual-asic@iis.fraunhofer.de`** went out
**27 October 2026, 16:47:47 −0700** (23:47:47 UTC) from **Dave Cook `<dave@gridworkz.com>`**, carrying
both prepared files. The attachments were staged in the draft through the mailbox itself — the
connected mail integration's attachment field accepts only stored file references, never a local
path — and the draft was then sent through that integration. Receipts, read from the sent message and
not from the draft:

| | |
|---|---|
| Subject | `GF180MCU via EUROPRACTICE — NDA request form and questionnaire (GRX930)` |
| Message id | `1a17fc34b4f1a94c`, thread `1a17f9f9e912e25c`, labelled **SENT** |
| Attachment | `NDA_Request_Form_GF_Rev2.0-1_prepared.docx` — 24,187 B — sha256 `1b918917e766c65fd300e6cfbcbbfcdbd151ec69090a1fa22d257b1529333f82` |
| Attachment | `GF_Template_PDK_request_prepared.pptx` — 3,648,739 B — sha256 `8b7ab88d66a2e90fb1dfa2c86006c762dce0879aab93880aef0fc9825b7c74fd` |
| Body | the cover line below, verbatim; Gmail linkified the phone number and the e-mail address in the stored copy, and the text is otherwise unchanged |

The verification is against the sent message, not the draft: the Sent copy was read back through the
Gmail API, and **both attachments were downloaded from it and hashed — both match the digests above**,
so the bytes Fraunhofer IIS received are the prepared files themselves. What remains is the entity's
signature, which goes on the NDA itself.

## What the form answers

| Field | Value |
|---|---|
| Company | Gridworkz |
| Department | `N/A` — a single-owner company; nothing to name |
| Address | 1931 Norris Ave. / Fort Erie, Ontario L2A5M4 / Canada (three lines in the one cell) |
| Signatory | **Dave Cook, Owner** — the form's *Name of the person signing the NDA* and *Job Title* |
| PDK contact | Dave Cook, Owner — the same person as the signatory |
| Phone (both contact lines) | +1 289-303-7651 |
| Technology | **Others: GF180MCU (180 nm), 5-metal (5LM), 1.8 / 3.3 / 5 V, open-source PDK** — the list above it (`130BCDlite-GEN2`, `8XP (SiGe)`, `55LPE-RF`, `45RFSOI`, `45SPCLO`, `28SLPe`, `22FDX`, `12LP+`) is advanced-node only and does not include GF180MCU, so this is the field the technology actually goes in |
| Research activities | open-source RISC-V processor and accelerator silicon; the GRX930 test chip already in a wafer.space pooled GF180MCU run; development public at <https://github.com/kubeworkz> |
| Product and final end use | quad-core RV64IMAC SoC + two 8×8 systolic-array accelerators, shared 64 KB L2, 160 KB on-chip 5 V SRAM, `gf180mcu_fd_sc_mcu7t5v0` cells and `gf180mcu_fd_ip_sram` macros, 7.864 × 20.488 mm (161 mm²), custom pad ring, chip-on-board; general-purpose embedded computing and neural-network inference on evaluation and development boards; no military application |
| Military application | **☒ No** (the box is ticked), with the description line stating it is not applicable |
| End user | Gridworkz and its development partners, on evaluation boards; developed as open-source hardware |
| Target volume | **☒ MPW Run — 1–2 designs per year**; Engineering Run and Volume Production left unticked, wafers-per-year marked `n/a` |
| EUROPRACTICE member number | None yet — first order |

## What the deck answers

* **Slide 1** — title and subtitle naming the part and this request.
* **Slide 2 (Overview)** — project title, affiliation (Gridworkz — Fort Erie, Ontario, Canada), main
  contact (Dave Cook), target technology, target application, **application classification pruned to `12) AI; 14) Compute`** (the
  template says to remove everything not applicable), and the brief overview with the measured areas.
* **Slide 3 (Partner Information)** — who Gridworkz is and where the programme stands.
* **Slide 4 (Technical Information)** — state of the art, what will be new (with the FPGA-validated
  121 MHz figure), and the expected timeline (final GDS Q4 2026 – Q1 2027; tape-out on the next
  GF180MCU registration we can secure).
* **Slide 5 (Supporting Project Information)** — the measured evidence: 0-overflow global routing,
  1,710 antenna-repair diodes in-flow, post-repair setup STA closing 40 ns at −0.064 ns, structural
  netlist-vs-layout `MATCH` (53,745 instances), density 31.27 % COMP / 26.25 % Poly2.

Three of the template's answer boxes are single-line boxes (slide 2's is 3.03 in, slides 3–5 are
0.30 in); `fill_pack.py` enlarges the four that now hold real answers, because a one-line box cannot
show a paragraph. Nothing else about the template's layout is touched.

## What remains

**Nothing is marked in either document.** All 19 text fields of the form and all five slides of the
deck are filled, the entity's own details included. Nothing is left to supply; the send is recorded above, and what remains is the
signature on the NDA.

The form is **not** protected (`w:documentProtection … w:enforcement="0"`), its `sdtLocked` flags sit
only on the ballot boxes and stop a box being deleted, not ticked, and every text field is a plain
content control — so anything the signatory wants to adjust is editable in Word with no unlocking
step.

**The signature is not on this form.** It goes on the NDA itself, which Fraunhofer IIS returns once the
request is accepted. EUROPRACTICE's own wording on that page: *"There must be legal binding Signatures
on NDA: Global Foundries only concludes agreements with companies and universities/Research institutes,
NOT with individuals. All agreements have to be signed by an official representative or a legally
authorized person."* So the counterparty is the company, the signer must be an official representative
or a legally authorised person, and that is the step an agent cannot take.

## How it was sent

One email to **Syed Shahnawaz, `virtual-asic@iis.fraunhofer.de`** (+49 9131 776 4425), with both prepared
files attached and *in the formats the page asks for* (the form in .docx, the deck as PowerPoint) — sent
27 October 2026, as the section above records. The cover line, as sent:

> Dear Mr Shahnawaz,
>
> Following our enquiry of 27 October about the maximum GF180MCU die size: attached are the GlobalFoundries
> NDA request form and the project questionnaire for GRX930, our quad-core RISC-V SoC with two
> systolic-array accelerators (161 mm², 7.864 × 20.488 mm).
>
> The size question is still the one that decides whether we proceed with this part — a written maximum
> design area, and how a die this size would be quoted. These documents start the NDA process in
> parallel so that nothing waits on it.
>
> Kind regards,
> Dave Cook, Owner — Gridworkz
> dave@gridworkz.com · +1 289-303-7651

## The rest of the process, as published

* **The NDA is with GlobalFoundries, the order is with Fraunhofer IIS.** The access page says GF
  concludes the agreements; EUROPRACTICE's Terms & Conditions
  (<https://europractice-ic.com/requests/terms-conditions/>) name the customer-facing party as the
  selected **MPW Center**, and list `Fraunhofer-Institut (FhG-IIS), Am Wolfsmantel 33, D-91058 Erlangen,
  Germany` as one. The NDA text itself is not public, so its exact GF legal entity is not settled by any
  page we could read.
* **Registration and the summary form come later.** The same terms: *"After completion of this form,
  CUSTOMER has to send the summary form, duly signed by its authorized signatory"* and *"Only when the
  signed summary form is received by the MPW Center and the design is checked for design errors, the
  MPW Center can accept the design for prototyping."* The portal
  (<https://europractice-ic.com/access-and-registration/>) is where projects, quotes and export
  compliance are handled.
* **Export control may add one questionnaire.** The terms say *"CUSTOMER undertakes to complete any
  questionnaire required to assess the dual-use status of the Items"* and carry the end-use undertaking
  (no weapons of mass destruction, no military end-use in embargoed countries). The form's military
  question is answered No on that basis; if the dual-use questionnaire arrives, the answer is the same
  project description as slide 2.

## Reproduce / verify

```
cd nda_pack
python fill_pack.py        # rewrites both _prepared files from the untouched originals
```

Re-running is safe and deterministic — the originals' sha256 above stay unchanged, and the prepared
files produced here hash to
`1b918917e766c65fd300e6cfbcbbfcdbd151ec69090a1fa22d257b1529333f82` (form) and
`8b7ab88d66a2e90fb1dfa2c86006c762dce0879aab93880aef0fc9825b7c74fd` (deck). Verification run on both
prepared files: every XML part parses (20 and 92 parts), both zips pass `testzip`, no `Click here to
enter text.` placeholder survives, exactly two boxes are ticked (☒) and eleven remain unticked, and the
filled values read back field for field. The one thing not verifiable here is how Word and PowerPoint
*paint* the result — the check is at the file-format level.
