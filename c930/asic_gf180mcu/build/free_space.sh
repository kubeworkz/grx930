#!/bin/bash
# free_space.sh -- compress regenerable derived artifacts of the SUPERSEDED
# pre-Option-B runs (Sept 22-23) so the two queued flow arms have disk headroom.
# Nothing is deleted; all three file types regenerate from RTL:
#   *.sdf            STA timing dumps (3 corners x ~296 MB per run)
#   *.nl.v.json      yosys netlist JSON (~340 MB per run)
#   primitive_techmap.dot  yosys techmap debug graph (175 MB-972 MB)
set -u
D=/home/ubuntu/grx930_ol2/drt_fast
touch $D/compress.running
cd /home/ubuntu/grx930_ol2/openlane2_rtl/runs || exit 1
for r in RUN_2026-09-22_15-09-48 RUN_2026-09-23_01-58-03 RUN_2026-09-23_16-04-17 RUN_2026-09-23_20-00-34; do
  [ -d "$r" ] || continue
  find "$r" -type f \( -name "*.sdf" -o -name "*.nl.v.json" -o -name "primitive_techmap.dot" \) \
    -size +50M 2>/dev/null | while read -r f; do
      nice -n 19 gzip -1 "$f" 2>/dev/null && echo "gz $f"
    done
done
df -h /home | tail -1
rm -f $D/compress.running
