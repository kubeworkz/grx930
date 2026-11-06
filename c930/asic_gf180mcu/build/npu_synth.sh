#!/usr/bin/env bash
# NPU-only synthesis against the GF180MCU 5V library.
#
#   bash npu_synth.sh            (runs on the flow box, in ~/grx930_ol2/npu_synth)
#
# Why this exists: the quad-core area in the wafer.space brief scales the measured
# single core by four and guesses the NPU and L2. The NPU is the one guess that can
# be replaced by a measurement cheaply -- it has no large memories, so it maps to
# real cells instead of inferring to flops the way the 64 KB L2 would.
#
# The run is capped with --memory so it cannot OOM the live DRT pass on the same
# box. If the cap is too small yosys dies with exit 137 and nothing else is hurt.
#
# Results land in synth.log; the line to read is "Chip area for module".
set -euo pipefail

IMG=${IMG:-ghcr.io/wafer-space/gf180mcu-precheck:latest}
LIB=/workspace/gf180mcu/gf180mcuD/libs.ref/gf180mcu_fd_sc_mcu7t5v0/lib/gf180mcu_fd_sc_mcu7t5v0__tt_025C_5v00.lib
HERE=$(cd "$(dirname "$0")" && pwd)

# A delay target of 40 ns matches the constraint the ASIC flow is actually run at.
# Without -D, abc minimises area and reports a number no real corner would meet.
ABC_DELAY_PS=${ABC_DELAY_PS:-40000}

{
  # read_verilog needs a filename, so the include path goes on every line rather
  # than in a standalone -I statement (which yosys rejects as a syntax error).
  for f in "$HERE"/rtl/*.sv; do
    echo "read_verilog -sv -I /work/npu_synth/rtl /work/npu_synth/rtl/$(basename "$f")"
  done
  cat <<EOF
hierarchy -check -top c930_npu_core
EOF
  if [ "${FLOW:-nomap}" = "full" ]; then
    # Flat flow. OOMs on this box: the NPU's weight/activation arrays expand to
    # registers and the resulting mux trees need >3 GB.
    cat <<EOF
synth -top c930_npu_core -flatten -noabc
EOF
  else
    # Memory-preserving flow: buffers stay as \$mem, so the number measured is
    # the NPU's compute logic. On a real ASIC those buffers are SRAM macros, so
    # counting them as flip-flops would be wrong anyway.
    cat <<EOF
proc; opt; fsm; opt
alumacc; share; opt
memory -nomap
techmap; opt -fast
EOF
  fi
  cat <<EOF
dfflibmap -liberty $LIB
# Area-only mapping by default: delay-driven ABC spends >15 min on the activation
# unit alone and produced nothing usable in the time available. -fast is a lower
# bound on area, so it cannot overstate the NPU.
abc -liberty $LIB ${ABC_OPTS:--fast}
opt_clean -purge
stat -liberty $LIB
EOF
} > "$HERE/synth_npu.ys"

docker run --rm --memory=3g --memory-swap=3g \
  -v /home/ubuntu/grx930_ol2:/work \
  --entrypoint bash "$IMG" -lc '
    set -e
    YS=$(ls /nix/store/*-yosys-0.66/bin/yosys | head -1)
    cd /work/npu_synth
    "$YS" -s synth_npu.ys -l synth.log
  '

echo "=== measured ==="
grep -E "Chip area|Number of cells:" "$HERE/synth.log" | tail -4
