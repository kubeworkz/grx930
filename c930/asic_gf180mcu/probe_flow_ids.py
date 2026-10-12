import inspect

import openlane.flows.sequential as S

src = inspect.getsource(S)
lines = src.splitlines()

# 1) the matchable / no-step-with-ID region (~line 276 of file, find in source)
for i, line in enumerate(lines):
    if "no step(s) with ID" in line:
        lo = max(0, i - 40)
        hi = min(len(lines), i + 25)
        print("--- MATCH LOGIC ---")
        for j in range(lo, hi):
            print(f"{j}: {lines[j]}")
        print()

# 2) dedup: search for where instance ids are numbered
for i, line in enumerate(lines):
    low = line.lower()
    if ("id" in low and ("count" in low or "occur" in low or "seen" in low)) or "-1" in line or "slugify" in low:
        print(f"DEDUP[{i}]: {line.rstrip()}")
