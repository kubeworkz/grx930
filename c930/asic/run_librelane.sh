#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# run_librelane.sh -- the SKY130 chip through LibreLane, on a prebuilt sky130A.
#
#   ./run_librelane.sh --fetch-pdk          host side: put sky130A under $PDK_ROOT
#   ./run_librelane.sh                      flow image: run the Classic flow
#   ./run_librelane.sh -T Yosys.Synthesis   any other flag goes to librelane
#   SYNTH_PARAMETERS="ENABLE_NPU1=0" ./run_librelane.sh
#                                           extra SoC generics, as chparam
#   SKY130_SYNTH_STOP_AFTER_DFFLIBMAP=1 ./run_librelane.sh -T Yosys.Synthesis
#                                           stop after dfflibmap, write netlist
#
# PDK_ROOT defaults to /opt/pdk; RUN_TAG defaults to sky130_<UTC timestamp>.
#
# WHY THIS EXISTS
#
#   The SKY130 path used to install its PDK by building skywater-pdk, whose
#   `make timing` runs inside a conda environment that thirds_party/make-env
#   downloads at build time. That broke in CI on a pip dependency conflict in a
#   2020-era requirements file, and it was the wrong shape anyway.
#
#   sky130A now arrives the way the GF180 arms' PDK does: prebuilt, from the
#   same catalogue (`ciel`), stored under the same `<PDK_ROOT>/<pdk>` layout, and
#   handed to LibreLane with `--manual-pdk` so the flow never fetches a PDK
#   mid-run. The version is not chosen here -- it is read out of the engine's own
#   `librelane/pdk_hashes.yaml`, i.e. the commit the running LibreLane release was
#   tested against. A PDK that no longer matches the engine cannot be picked by
#   accident, and there is no second place to bump.
#
#   The tree matters as much as the version: a PDK release carries its tool
#   configuration in libs.tech/<tool>/, and LibreLane 3 reads its variables from
#   libs.tech/librelane/config.tcl. The 2022-era tag that used to be fetched here
#   only had libs.tech/openlane/ (the LibreLane 2 layout), so the flow found
#   PDN_VPITCH and KLAYOUT_DEF_LAYER_MAP undefined and refused to start with
#   "This PDK may be incompatible with your flow". ciel resolves through the
#   engine's pinned hash, and that release has the librelane tree.
set -euo pipefail

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# SKY130_PDK_ROOT, not PDK_ROOT: the flow image exports PDK_ROOT=/workspace/gf180mcu,
# its own baked-in GF180 root. Taking that name would fetch sky130A into a path
# inside the image, and the tree would be gone when the container exits -- which is
# what a first attempt did (ciel reported "installed at /workspace/gf180mcu" and
# nothing landed on the host). The GF180 arm keeps using the image's PDK_ROOT; this
# flow names its own root instead.
PDK_ROOT=${SKY130_PDK_ROOT:-/opt/pdk}
PDK=sky130A
SCL=sky130_fd_sc_hd

# Read by the flow; the presence of this file is how fetch and run both decide
# the PDK is complete, because it is the one the config maps the design to.
TT_LIB="$PDK/libs.ref/$SCL/lib/${SCL}__tt_025C_1v80.lib"
# The engine reads its PDK variables from here. Absent (the LibreLane 2 layout)
# and every PDK variable comes up undefined.
PDK_TCL="$PDK/libs.tech/librelane/config.tcl"

# The sky130 commit the running LibreLane pins. Both fetch and run derive it the
# same way, so the tree that is installed is the tree the engine expects.
pinned_version() {
  python3 - "$PDK_FAMILY" <<'PY'
import sys
import librelane, os, yaml
path = os.path.join(os.path.dirname(librelane.__file__), "pdk_hashes.yaml")
with open(path) as f:
    family = sys.argv[1]
    hashes = yaml.safe_load(f)
if family not in hashes:
    sys.exit(f"::error::{path} has no entry for {family}")
print(hashes[family])
PY
}

PDK_FAMILY=sky130

fetch_pdk() {
  if [ -f "$PDK_ROOT/$TT_LIB" ] && [ -f "$PDK_ROOT/$PDK_TCL" ]; then
    echo "$PDK already present at $PDK_ROOT"
    return 0
  fi
  command -v ciel >/dev/null 2>&1 || {
    echo "::error::ciel is not on PATH -- run this inside the flow image" >&2
    exit 1
  }
  version=$(pinned_version) || exit 1
  echo "fetching $PDK $version from ciel into $PDK_ROOT"
  mkdir -p "$PDK_ROOT"
  # fetch puts the release in ciel's store; enable links it in at <PDK_ROOT>/<pdk>,
  # which is the path --manual-pdk is given later.
  ciel fetch --pdk "$PDK" --pdk-root "$PDK_ROOT" "$version"
  ciel enable --pdk "$PDK" --pdk-root "$PDK_ROOT" "$version"
  # Prove the tree is usable rather than trusting ciel: without the librelane
  # config the flow starts and then rejects the PDK variable by variable.
  for f in "$TT_LIB" "$PDK_TCL"; do
    [ -f "$PDK_ROOT/$f" ] || {
      echo "::error::enabled $PDK $version but $PDK_ROOT/$f is missing" >&2
      exit 1
    }
  done
  echo "$PDK $version installed at $PDK_ROOT"
}

run_flow() {
  if command -v librelane >/dev/null 2>&1; then
    LR=librelane
  else
    echo "::error::librelane is not on PATH -- run this inside the flow image" >&2
    exit 1
  fi
  [ -f "$PDK_ROOT/$TT_LIB" ] || {
    echo "::error::no $PDK at $PDK_ROOT -- run '$0 --fetch-pdk' first" >&2
    exit 1
  }
  [ -f "$PDK_ROOT/$PDK_TCL" ] || {
    echo "::error::$PDK_ROOT/$PDK_TCL is missing: this $PDK predates libs.tech/librelane" >&2
    echo "::error::and LibreLane 3 would fail on undefined PDK variables; re-run '$0 --fetch-pdk'" >&2
    exit 1
  }
  tag=${RUN_TAG:-sky130_$(date -u +%Y%m%d_%H%M%S)}

  echo "engine   $LR $($LR --version 2>&1 | head -1)"
  echo "pdk      $PDK at $PDK_ROOT ($(pinned_version 2>/dev/null || echo 'version unpinned'))"
  echo "tag      $tag"

  cd "$HERE"

  # The SoC's boot ROM loads its firmware with $readmemh, and Yosys resolves that
  # path against the *step's* working directory (librelane/runs/<tag>/<NN-step>/),
  # not against the RTL or this config.  The RTL default is the repo-relative
  # "sw/boot.hex", so Generate JSON Header failed with
  # "Can not open file `sw/boot.hex' for $readmemh" before the flow ever reached
  # synthesis.  Hand the SoC an absolute path computed from this script's own
  # location: that is the same path whether the flow runs inside the image (repo
  # at /work) or natively, and a missing image is caught here rather than as a
  # Yosys error five steps in.
  BOOT_HEX=$(CDPATH= cd -- "$HERE/../sw" && pwd)/boot.hex
  [ -f "$BOOT_HEX" ] || {
    echo "::error::no boot ROM image at $BOOT_HEX" >&2
    echo "::error::c930/sw/boot.hex is the bootrom stub image (c930/sw/*.hex is gitignored);" >&2
    echo "::error::copy it from a tree that has run the SoC sims/builds" >&2
    exit 1
  }
  # SYNTH_PARAMETERS is LibreLane's list of Yosys `chparam` pairs, applied
  # before elaboration by both Yosys steps that matter here: Generate JSON
  # Header (which is where $readmemh runs) and Synthesis.  The boot image is
  # always the first entry.  Entries from the caller's SYNTH_PARAMETERS follow
  # it, so the SoC's generics (ENABLE_NPU1, L2_NUM_SETS, ...) are set from the
  # flow rather than by editing the RTL.  Each entry is NAME=VALUE and the
  # launcher does not parse the value, so it may not contain whitespace.
  PARAMS=( "BOOT_INIT_FILE=\"$BOOT_HEX\"" )
  if [ -n "${SYNTH_PARAMETERS:-}" ]; then
    # read -a, not an unquoted expansion: a value may contain a glob character
    # and must reach Yosys literally.
    read -r -a EXTRA <<<"$SYNTH_PARAMETERS"
    for p in "${EXTRA[@]}"; do
      case $p in
        [A-Za-z_]*=*) PARAMS+=( "$p" ) ;;
        *)
          echo "::error::SYNTH_PARAMETERS entry '$p' is not NAME=VALUE" >&2
          exit 2
          ;;
      esac
    done
  fi
  echo "params   ${PARAMS[*]}"

  # Stop-after-dfflibmap checkpoint (`make mapped`).  LibreLane discovers
  # modules named librelane_plugin_* on PYTHONPATH; the plugin in
  # librelane/plugin/ swaps in a patched synthesize.py that writes the netlist
  # after dfflibmap and exits before the ABC strategy pass.  The flow has to
  # stop at Yosys.Synthesis: the checkpoint's combinational cells are Yosys
  # `$_` gates, so no later step can use what follows.
  if [ "${SKY130_SYNTH_STOP_AFTER_DFFLIBMAP:-0}" = 1 ]; then
    to=""
    previous=""
    for argument in "$@"; do
      case $argument in
        --to=*) to=${argument#--to=} ;;
      esac
      case $previous in
        -T | --to) to=$argument ;;
      esac
      previous=$argument
    done
    if [ "$to" != "Yosys.Synthesis" ]; then
      echo "::error::SKY130_SYNTH_STOP_AFTER_DFFLIBMAP needs -T Yosys.Synthesis (got '${to:-none}')" >&2
      exit 2
    fi
    export PYTHONPATH="$HERE/librelane/plugin${PYTHONPATH:+:$PYTHONPATH}"
    echo "stop     after Yosys.Synthesis's dfflibmap (mapped netlist, no ABC strategy pass)"
  fi

  # The overlay has to sit beside config.yaml, not in /tmp: LibreLane expands
  # `dir::` against the directory of the last configuration file it loaded, so an
  # overlay elsewhere re-points every dir:: in this design's config (the first
  # attempt resolved ../sky130_asic_wrapper.sv against /tmp and stopped at load).
  OVERLAY=$HERE/librelane/boot_hex.yaml
  {
    echo "# Written by run_librelane.sh on every run; see the comment there."
    echo "SYNTH_PARAMETERS:"
    # Single-quoted YAML scalars: a value may contain ':' or '#', and the boot
    # image's value carries the double quotes Yosys needs for a string constant.
    for p in "${PARAMS[@]}"; do
      esc=${p//"'"/"''"}
      printf "  - '%s'\n" "$esc"
    done
  } >"$OVERLAY"

  # Same shape as ws_exec.sh: --manual-pdk because the PDK is already here, and
  # the config last so every flag before it wins.  The overlay is after it, so
  # the boot image path cannot be overridden by the design config.
  exec "$LR" \
    --pdk "$PDK" \
    --pdk-root "$PDK_ROOT" \
    --manual-pdk \
    --scl "$SCL" \
    --run-tag "$tag" \
    "$@" \
    librelane/config.yaml \
    "$OVERLAY"
}

case "${1:-}" in
  --fetch-pdk) fetch_pdk ;;
  *) run_flow "$@" ;;
esac
