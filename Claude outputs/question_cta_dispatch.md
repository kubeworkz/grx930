# grxcp → grxgpu: where does per-CTA launch cost live, and which backend is right?

A question rather than a report. We have a measurement we trust and an
interpretation we do not, and the difference decides a roadmap item — so we
would rather ask than guess. We have already labelled it wrongly once today and
retracted that in our own docs before sending this.

## The measurement

A kernel that does nothing but timestamp itself. Its first instruction is a
plain `csrr` on MCYCLE — no fence, no memory access, nothing of ours in front
of it. Every block writes its own entry time to its own slot, so we can see the
distribution rather than one warp's view. rtlsim, 4 cores, 16 threads/block:

| blocks | earliest entry | latest entry | spread |
|---|---|---|---|
| 1 | 2910 | 2910 | 0 |
| 2 | 4462 | 4480 | 18 |
| 4 | 7198 | 13453 | 6255 |
| 8 | 21819 | 29328 | 7509 |
| 16 | 45221 | 57615 | 12394 |
| 32 | 68872 | 90206 | 21334 |
| 64 | 100774 | 124372 | 23598 |

Two things fall out of the same run and are not in dispute:

* `vx_rdcycle_sync`'s fence costs **27 cycles** at kernel entry. The instrument
  is not the story.
* The first load from the argument blob, cold dcache, costs **18 cycles**.
* The one-block floor is **1828–2910**, so fixed bring-up is real and small.

## The part we cannot resolve from here

**The EARLIEST block's entry grows with the grid**, from 2910 to 100774. Not
just the last block — the first one to arrive anywhere.

We initially wrote that up as hardware CTA dispatch at roughly 1500 cycles per
CTA. Then we read `sw/kernel/src/vx_spawn.c` and retracted it, because block
distribution is a **software loop in the CTA runtime**:

```c
uint32_t start_group  = targs->group_offset + local_group_id;
uint32_t group_stride = groups_per_core;
uint32_t end_group    = start_group + iterations * group_stride;

for (uint32_t group_id = start_group; group_id < end_group; group_id += group_stride) {
  blockIdx.x = group_id % gridDim_x;
  ...
  callback((void*)arg);
}
```

A warp group running four blocks back to back naturally produces later entry
times for the later ones, with no hardware dispatcher involved. That accounts
for the *spread* easily.

**It does not account for the earliest entry moving.** With 64 warp slots and
4 warps per group there are 16 resident groups, so at 16 blocks every group has
exactly one, and the first one should start about when it starts at 1 block. It
does not — 2910 becomes 45221.

So: is the earliest entry gated by something that must complete for the whole
grid before any group runs — the KMU descriptor, the DCR programming, warp
spawn — or is our reading of the distribution wrong?

## And the two backends disagree past residency

Same experiment, simx, same 4 cores:

| blocks | earliest entry | latest entry |
|---|---|---|
| 1 | 3030 | 3030 |
| 4 | 6863 | 7672 |
| 16 | 26408 | 29406 |
| 32 | **26408** | 33157 |
| 64 | **26416** | 34756 |

**simx plateaus at exactly residency** — 16 blocks × 4 warps = 64 warps = 4
cores × 16 warps. Past that, blocks queue behind retiring ones and the earliest
entry stops moving. That is the behaviour we would expect and want.

**rtlsim does not plateau**: 45221, 68872, 100774. It keeps climbing well past
the point where the machine is full.

One of those is wrong about the design. We cannot tell which from here, and it
is exactly the class the fidelity contract exists for.

## Why we are asking rather than proceeding

This decides a roadmap item, and the two answers point opposite ways:

* If the cost is in the **CTA runtime**, it is software, it is fixable, and it
  is probably the highest-value optimisation available to either team — it
  currently sits at roughly 40% of a transformer block at our shapes.
* If it is in the **hardware dispatcher**, it is a multi-SM scaling wall. A
  128-SM part wants thousands of CTAs in flight, and nothing in the software
  stack can amortise a serial per-CTA cost. It would belong in the hardware
  plan ahead of widening the SM.

Three specific questions:

1. Between the KMU descriptor write, warp spawn, and `process_thread_groups`,
   what has to complete for the **whole grid** before the first group can run?
2. Is rtlsim's failure to plateau past residency the design's behaviour, or the
   simulation shim's?
3. Is there an existing counter — or a cheap one to add — that separates
   "descriptor and spawn" from "first callback entered"? We can add device-side
   probes but not RTL-side ones, and the split is exactly what we lack.

The kernel and host are in `tests/repro/launch_preamble/`, about seventy lines
between them, if you want to run it against a configuration of your own.
