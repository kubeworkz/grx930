#!/usr/bin/env bash
# After the LVS verdict: partition the lvsdb and print the census the census watcher produced.
set -u
S=/home/ubuntu/grx930/c930/asic_gf180mcu
cd "$S" || exit 2
RUN=build/lvs_chip/rebased-b12300
echo "post start $(date -u)"
for i in $(seq 1 400); do
    [ -f "$RUN/verdict.json" ] && break
    sleep 30
done
if [ ! -f "$RUN/verdict.json" ]; then echo "[[NO VERDICT]] $(date -u)"; exit 1; fi
echo "[[VERDICT]] $(date -u)"
docker run --rm -v "$S:/work" -w /work ghcr.io/efabless/openlane2:2.3.10 \
    klayout -b -r build/lvs_chip/probe/lvsdb_xref.rb \
    -rd file=build/lvs_chip/rebased-b12300/report.lvsdb > "$RUN/xref.txt" 2>&1
echo "xref rc=$?"
grep -E "^CIRCUITS|^NL |^PAIR|^NET|^DEV|^== " "$RUN/xref.txt" | head -50
echo "--- driver tail"
tail -5 "$RUN/driver.log"
echo "[[CENSUS (from the census watcher)]]"
cat build/lvs_chip/evidence_census/rebased-census/census.txt 2>/dev/null | head -14
echo "[[POST DONE]] $(date -u)"
