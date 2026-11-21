#!/bin/bash
# Full-chip metal+via DRC, both files, once the machine has the ~4.4 GB the flat
# run needs.  Detached; progress goes to /tmp/stage6/full2.log.
cd /mnt/c/Users/kubew/grx930 || exit 1
D=c930/asic_gf180mcu/libs.tech/klayout/tech/drc/gf180mcu.drc
O=build/lvs_chip/eco_drop_2x2/stage6/full_drc
L=metal1,metal2,metal3,V1.1,V1.2a,V1.2b,V1.3a,V1.3c,V1.3d,V1.4a,V1.4b,V1.4c,V2.1,V2.2a,V2.2b,V2.3b,V2.3c,V2.3d,V2.4a,V2.4b,V2.4c
IMG=ghcr.io/efabless/openlane2:2.3.10

wait_free() {
  for i in $(seq 1 720); do
    V=$(pgrep -fc "[v]erilator_bin" 2>/dev/null || true); V=${V:-0}
    A=$(free -m | awk '/^Mem:/{print $7}')
    if [ "$V" -eq 0 ] && [ "${A:-0}" -ge 3500 ]; then
      echo "FREE avail=${A}MB after $((i*30))s $(date -u)"
      return 0
    fi
    [ $((i % 20)) -eq 0 ] && echo "waiting: verilator=$V avail=${A}MB $(date -u)"
    sleep 30
  done
  echo "WAIT_TIMEOUT verilator=$V avail=${A}MB $(date -u)"
  return 1
}

run_one() {  # $1 input, $2 report
  A=$(free -m | awk '/^Mem:/{print $7}')
  echo "START $1 avail=${A}MB $(date -u)"
  docker run --rm -v /mnt/c/Users/kubew/grx930:/work -w /work --entrypoint klayout "$IMG" \
    -b -r "$D" -rd input="/work/$1" -rd report="/work/$2" \
    -rd topcell=grx930_test_chip -rd variant=gf180mcuD -rd metal_level=5LM \
    -rd run_mode=flat -rd threads=1 -rd decks="$L"
  echo "RC=$? report=$2 $(date -u)"
}

wait_free || exit 2
run_one build/lvs_chip/rebased_tap_stream_out_filled_stitched_fix16.gds "$O/before.lyrdb"
run_one build/lvs_chip/eco_drop_2x2/stage6/grx930_test_chip_final.gds "$O/after.lyrdb"
echo ALLDONE $(date -u)
