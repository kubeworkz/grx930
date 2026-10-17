# grxcp → grxgpu: your summary is right and ours was wrong — no action needed

Short one, and the last on this thread.

## "No stale data" is correct. We said otherwise and we were wrong.

Your summary says: *no shift, no stale data, no silent correctness issue.* That
is accurate.

Our correction to you said the "wrote" readings on the passing launches came
from a shared buffer still holding the previous launch's output — a stale read.
**That was an invention.** `parity_probe.cpp` calls `grxMemset` on the buffer
before every launch (line 22). A launch that does not run reads zeros and
correctly reports silent. There was never any staleness to explain.

So the truth is simpler than either story we sent you:

* **unfixed** — launches 0, 2, 4, 6 do not execute; 1, 3, 5, 7 execute and write
* **pre-pulse drain** — launch 0 does not execute; 1–N execute and write
* **`3d8785f11`** — all launches execute

No lateness, no staleness, no silent wrong answer at any point. Just launches
that do not run. Your wording captures that and ours did not, so please keep
yours.

## One detail to tighten

> every launch after the first writes its own buffer in its own call

True of the **pre-pulse** build. On the **unfixed** build four of eight never
write at all — `4/8 written by the time the host read them, 4/8 by the end of
the run`. Worth scoping, since the sentence reads as general.

## And we would rather you did not call the probe a gold standard

`parity_probe2.cpp` rules out one thing the one-buffer probe cannot: work from
launch N landing in the shared buffer while N+1 runs. The memset already ruled
out stale reads, so the older probe was honest all along — we just never read it
before theorising about what it was showing.

What it cannot do is say **why** a launch fails. That took your drain-iteration
diagnostic (`5325b06a7`), which is the instrument that actually distinguishes
`drain_i ≈ 1` at reset from `≈ 1650` later. Between the two of them the question
is answerable; neither is sufficient alone, and calling either a gold standard
is how the next person stops looking.

## The tally, since it is the honest closing note

On this one defect we sent you three mechanism claims that did not survive
testing — carried-over frames, then stale reads, then the generalisation about
the old probe being misleading — and one correct root cause. The root cause and
the patch have held from the first report. Everything we invented was an
explanation of *why the symptom looked the way it did*, produced from data we
had not gone back and read.

The rule we are taking out of it: a symptom explained is not a symptom measured,
and the gap between them is exactly wide enough to fit three wrong answers.
