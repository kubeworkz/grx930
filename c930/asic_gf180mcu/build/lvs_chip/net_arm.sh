#!/bin/bash
# net_arm.sh -- run the LVS deck's netlist phase on one layout, with a hard cap, and record what it did.
#
# The comparison this exists for: the same die before and after `tools/lvs_chip/merge_layers.py`, with
# the same deck, the same switches and the same thread count, so the only variable is the layout. The
# deck is `build/lvs_chip/deck_probe/gf180mcu.lvs` -- the probe deck, which returns at the comparison
# banner and dumps the extracted netlist when `net_only` is set -- because the stock deck's comparison
# section dies on an undefined flag (see tools/klayout_lvs.sh). `run_mode=deep` is the configuration
# that was measured at 5 h 46 min without returning on the pre-fix stream.
#
# The cap is enforced by stopping the **container**, not by `timeout` on the client: killing the client
# leaves the container running, and a run still computing after the cap is exactly the result this
# script has to report.
#
#   bash build/lvs_chip/net_arm.sh merged   c930/asic_gf180mcu/build/lvs_chip/stream_out_merged.gds 2400
#   bash build/lvs_chip/net_arm.sh unmerged c930/asic_gf180mcu/build/lvs_chip/stream_out.gds        2400
#
# Writes <out>/klayout.log, <out>/run_deck.sh (the exact command), <out>/arm.json. Exit 0 if the
# netlist appeared, 1 if the cap stopped it, 2 if the deck failed on its own before that.
#
# The `pmap` stub is not decoration: the deck shells out to `pmap` and dies in its own logger without
# it (`undefined method 'strip' for nil` at gf180mcu.lvs:76), which is the failure this script showed
# on its first attempt. It must be on the container's PATH, so the stub goes in <out>/bin and the PATH
# is prepended by the container's own shell -- expanding the host PATH would be meaningless in there.
set -u
LABEL=${1:?label, e.g. merged}
IN=${2:?layout, repo-relative}
CAP=${3:-2400}

cd "$(dirname "$0")/../../../.." || exit 2   # lvs_chip -> build -> asic_gf180mcu -> c930 -> repo root
ROOT=$(cygpath -m "$PWD" 2>/dev/null || pwd)
OUT="c930/asic_gf180mcu/build/lvs_chip/net_arms/$LABEL"
rm -rf "$OUT"
mkdir -p "$OUT/bin"
NAME="lvs_net_$LABEL"
docker rm -f "$NAME" >/dev/null 2>&1

[ -f "$IN" ] || { echo "net_arm: no such layout: $IN" >&2; exit 2; }

printf '#!/bin/sh\necho "1234567 000"\n' > "$OUT/bin/pmap"
chmod +x "$OUT/bin/pmap"

cat > "$OUT/run_deck.sh" <<EOF
#!/bin/sh
PATH=/work/$OUT/bin:\$PATH
export PATH
exec klayout -b -r /work/c930/asic_gf180mcu/build/lvs_chip/deck_probe/gf180mcu.lvs \\
    -rd combine=true -rd check_ports=false -rd top_lvl_pins=true -rd run_mode=deep \\
    -rd verbose=false -rd metal_level=5LM -rd net_only=true -rd threads=4 \\
    -rd input=/work/$IN \\
    -rd schematic=/work/c930/asic_gf180mcu/build/lvs_chip/grx930_test_chip.cdl \\
    -rd topcell=grx930_test_chip \\
    -rd report=/work/$OUT/report.lvsdb \\
    -rd target_netlist=/work/$OUT/extracted.cir
EOF
chmod +x "$OUT/run_deck.sh"

start=$(date +%s)
MSYS_NO_PATHCONV=1 docker run --rm --name "$NAME" -v "$ROOT:/work" -w /work \
    ghcr.io/efabless/openlane2:2.3.10 sh "/work/$OUT/run_deck.sh" > "$OUT/klayout.log" 2>&1 &
pid=$!

stopped=no
while kill -0 "$pid" 2>/dev/null; do
    now=$(date +%s)
    if [ $((now - start)) -ge "$CAP" ]; then
        echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) CAP ${CAP}s reached -- stopping $NAME" | tee -a "$OUT/arm.log"
        docker stop -t 20 "$NAME" >/dev/null 2>&1
        stopped=yes
        sleep 3
        break
    fi
    sleep 15
done
wait "$pid" 2>/dev/null
rc=$?
elapsed=$(( $(date +%s) - start ))

netlist=no
[ -s "$OUT/extracted.cir" ] && netlist=yes
verdict=PASS
if [ "$netlist" = no ]; then
    if [ "$stopped" = yes ]; then verdict=CAP; else verdict=FAILED; fi
fi

cat > "$OUT/arm.json" <<EOF
{
  "label": "$LABEL",
  "input": "$IN",
  "input_bytes": $(stat -c%s "$IN" 2>/dev/null || echo null),
  "cap_seconds": $CAP,
  "elapsed_seconds": $elapsed,
  "netlist": "$netlist",
  "netlist_bytes": $([ "$netlist" = yes ] && stat -c%s "$OUT/extracted.cir" || echo 0),
  "container_exit": $rc,
  "stopped_by_cap": "$stopped",
  "verdict": "$verdict"
}
EOF
cat "$OUT/arm.json"
[ "$verdict" = PASS ] && exit 0
[ "$verdict" = CAP ] && exit 1
exit 2
