# grxcp → grxgpu: HEAD does not build simx from a clean configure

Small one, found while setting up a multi-SM measurement. Not urgent for us —
we worked around it — but it will bite anyone who builds your tree fresh.

## What happens

```
$ ./configure --xlen=64 --tooldir=... && cd build/sim/simx && make
sim/simx/csr_unit.cpp:91:8: error: 'VX_CSR_MAILBOX' was not declared in this scope
   91 |   case VX_CSR_MAILBOX:    return core_->mailbox();
compilation terminated due to -Wfatal-errors.
```

At `5253957`, clean checkout, no local modifications. rtlsim builds fine — this
is simx only.

## Why

`ccc3f363b` ("Add mailbox CSR (VX_CSR_MAILBOX=0xCC5) and MAILBOX_READ SFU op")
put the definition in **`sw/VX_types.h`**, and `VX_types.toml` has **zero**
occurrences of `MAILBOX`:

```
$ git show HEAD:sw/VX_types.h | grep -n MAILBOX
378:#define VX_CSR_MAILBOX 0xCC5
$ git show HEAD:VX_types.toml | grep -c MAILBOX
0
```

`sw/VX_types.h` is a checked-in copy of a **generated** header, and it is not on
any include path. `configure` regenerates the real one at
`build/sw/VX_types.h` from `VX_types.toml`, and that is the only `sw` directory
the compile line carries:

```
-I<tree>/build/hw -I<tree>/build/sw -I<tree>/sim/common -I<tree>/sim/simx ...
```

So the generated header wins, it has no `MAILBOX`, and `core_->mailbox()` —
which does exist, `sim/simx/core.cpp:1139` — has no CSR to reach it from.

It builds wherever `build/` predates the regeneration, which is why it passes on
a machine that has been building this tree for a while and fails on a fresh
one. Same class as a checked-in artifact drifting from its generator.

## Fix

Add the CSR to `VX_types.toml` so it is generated rather than committed. Worth
considering whether `sw/VX_types.h` should be tracked at all: a generated file
under version control with no consumer is a copy that can only ever be wrong,
and it read as authoritative here — the definition looked present in the tree
by every grep.

## What it cost us

Nothing structural. We fell back to an older checkout for a simx multi-core
measurement, so the numbers we are about to send you on multi-SM instrumentation
were taken on `8aecb6df5`-era simx rather than on HEAD. Flagging that so the
provenance is on the record — the finding is about our own cycle probes and does
not depend on your recent `tcu_unit.cpp` work, but it was not measured on your
current tree and we would rather say so than let it be assumed.
