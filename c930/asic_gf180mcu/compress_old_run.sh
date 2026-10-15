#!/bin/sh
# Compress the OLD campaign run's bulky artifacts in place (root needed:
# bind-mounted files are container-root-owned). Data kept as .zst.
# Targets RUN_2026-09-24_04-18-20 only - never the active v8 run.
R=/work/openlane2_rtl/runs/RUN_2026-09-24_04-18-20
find "$R" -type f \( -name '*.odb' -o -name '*.guide' -o -name '*.log' \) -size +10M -print0 \
  | xargs -0 -n1 -P2 zstd -q -f -T1 --rm
echo "COMPRESS_EXIT=$?"
du -sh "$R"
