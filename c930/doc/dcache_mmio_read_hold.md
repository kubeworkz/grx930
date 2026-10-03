# An MMIO load's data across a frozen pipeline

**Found** 2026-10-03, by `make pta_fw PTM_B=1`, while adding the PTA identity
words. **Fixed** in `rv64imac/RTL/riscv_core_dcache_top.sv`. **Gate:**
`make dcache_mmio_hold`.

A register read through MMIO could return another core's data. It needed three
things at once: an MMIO load, an I-cache fill on the cycle its response arrived,
and a second core using the MMIO bridge before the fill ended. On the four-core
SoC the third is supplied by the parked cores, which poll their release
registers through that bridge every eight hundred cycles or so each.

## 1. What was seen

`sw/pta_test.c` records `PTA_ERR_FOUND` after a calibration. On PTM-B it
recorded zero. The plan this firmware is gated against has 2,688 there, the
check on that register (T4, a second read a few instructions later) passed, and
the PTM-C build of the same firmware recorded 2,688.

Adding two more reads of the same register after the first made all three
return 2,688. Nothing before the first read had changed. That is the signature
of a fault that depends on where the code falls rather than on what it does, so
the firmware was put back exactly as it was and the harness was instrumented
instead:

```
t=18132 pc=00000c40 dc=0/1  ic=3/1                      the load reaches MEM
t=18133 pc=00000c40 dc=5/1  ic=0/1                      MMIO_READ; the I-cache misses on 0xc40
t=18135 pc=00000c40 dc=5/1  ic=1/1  csr_rv=1 rd=00000a80   the response: 0x0a80, correct
t=18137 pc=00000c40 dc=5/0  ic=1/1                      D-cache releases its stall ...
t=18138 pc=00000c40 dc=10/0 ic=1/1                      ... MMIO_RD_RETIRE, and waits
        ...                                             twelve more cycles of fill
t=18150 pc=00000c40 dc=10/0 ic=3/0                      the fill ends; the load leaves MEM
t=18161 pc=00000c50 dc=3/1         addr=00009458 data=0000000000000000 strb=0f
                                                        and what it stores is zero
```

`dc` is the D-cache's state and stall, `ic` the I-cache's. The register returned
the right value at 18135. The store a few instructions later wrote zero.

## 2. Why

`MMIO_READ` drops the D-cache's stall on the cycle the response arrives so the
load can move from MEM to WB. If something else is holding the pipe on that
cycle — an I-cache fill does, through the hazard unit's `stall_wb` — the load
stays in MEM. `MMIO_RD_RETIRE` exists for that case: it waits, with the request
deasserted, until the load has left, so the read is not issued a second time.
That state was added on 2026-09-10 for a UART FIFO that a duplicate read popped
twice, and it does that job.

While it waits it keeps the MMIO input selected onto the core's data mux, and
its comment says why: the load samples "the bridge's still-valid response" when
it leaves MEM. On one core the response is still valid. On four it is not:

- `c930_mmio_arb.sv` gives every core the same `i_mmio_read_data`. Only the
  `done` pulse is per core.
- The request has been deasserted, so the arbiter is free to grant the next
  core.
- Cores 1 to 3 are parked in the boot ROM reading `CORE*_RELEASE` through this
  bridge. They sleep about eight hundred cycles between polls, so the bridge is
  not busy — but a fill is a dozen cycles long and there are three of them.

When one of those polls lands inside the wait, the bus carries a parked core's
release value, which is zero, and that is what the load takes to WB when the
fill ends. The bridge's side of the same cycles, from a second instrumented run:

```
t=18133  arbiter grants core 0
t=18135  bridge rd_target=0 (the NPU's CSR)      bus=00000a80   the response
t=18137  bridge done                             bus=00000a80
t=18138  D-cache in MMIO_RD_RETIRE, arbiter idle bus=00000a80   still good, for four cycles
t=18142  arbiter grants core 2                   bus=00000a80
t=18143  bridge rd_target=3 (CORE2_RELEASE)      bus=00000000   core 2's poll: zero
t=18150  the fill ends, the load leaves MEM      bus=00000000   and that is what it takes
```

Core 2's poll arrived five cycles after core 0's response and eight before core
0's load could use it.

Which load is affected is decided by alignment and timing alone: it has to be
in MEM when fetch crosses into a cache line that is not yet in the I-cache, and
a parked core's poll has to fall in the dozen cycles that follow. That is why
one more line of C made it vanish, and why it shows as a wrong value in a
correct program rather than as a hang.

## 3. The fix

The D-cache latches the response on the `done` pulse and presents the latch for
the rest of the wait; on the `done` cycle itself the live input is used, so a
load that is not frozen is exactly as fast as it was. It is the same shape as
the latch the same file already keeps for an atomic's old value, and for the
same reason: an independent stall delays the capture past the point where the
source is still good.

Nothing else moves. The read is still issued once, the stall is still released
for the whole wait, and the cycle count of the firmware run that showed the
fault is unchanged at 35,787.

## 4. The gates

- **`make dcache_mmio_hold`** (`tb/tb_dcache_mmio_hold.sv`). The D-cache alone,
  with the MMIO side driven as a bus that somebody else takes over the cycle
  after the response. Four cases: unfrozen (the control), frozen for a fill's
  length with zero on the bus, frozen with all ones on the bus, and a second
  load to show the latch does not leak into it. Without the fix the four checks
  on held data fail and the control and every issued-once check pass, which is
  the bug and nothing else.
- **`make pta_fw PTM_B=1`**, unchanged firmware: `found 0` before, `found 2688`
  after, 35,787 cycles both times.

## 5. What it means for earlier results

Every firmware gate on this SoC since 2026-09-10 read its registers through this
path. None of them is known to have been affected: each either checks the value
it read against something independent, or passed in a layout where no MMIO load
met a fill. But "passed" is the weaker of those two, and a gate that records a
register without checking it — as `pta_test.c` did with this one — could have
recorded a zero and reported it as a measurement. The numbers this firmware
reports were re-read after the fix.

Seen in the same trace and left alone: a *cached* store that is in MEM during a
fill is written again each time the D-cache returns to idle, three times in the
case traced. The data and address are the same each time, so memory is right and
only the bus is busier; the MMIO store has `MMIO_WR_RETIRE` to prevent exactly
this, because for a START bit it is not harmless.
