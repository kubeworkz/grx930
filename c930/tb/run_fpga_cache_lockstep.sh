#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# DEPRECATED -- superseded by run_cache_split_lockstep.sh.
#
# The lockstep invariant now covers every hand-maintained copy of the cache
# sources -- the three rv64imac/RTL trees, the FPGA tree's src directory, the
# Branch_Prediction top and the tapeout tree -- instead of only the seven files
# the FPGA flow shares, and its tops leg is stronger than this check's
# cross-pair override comparison.  Rather than keep two overlapping gates, this
# entry point forwards to the generalised one so existing invocations keep
# working (the no-argument form behaves exactly as before).
#
# It takes no arguments: the old two-directory form (RTL_DIR FPGA_DIR) is not
# supported.  To point the check at a scratch copy, run
# run_cache_split_lockstep.sh ROOT, where ROOT is the directory the trees hang
# under.
set -u
if [ $# -ne 0 ]; then
  echo "run_fpga_cache_lockstep.sh is deprecated and takes no arguments." >&2
  echo "Use: $(cd "$(dirname "$0")" && pwd)/run_cache_split_lockstep.sh [ROOT]" >&2
  exit 2
fi
exec "$(cd "$(dirname "$0")" && pwd)/run_cache_split_lockstep.sh"
