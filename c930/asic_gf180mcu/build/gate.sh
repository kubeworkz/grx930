#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# gate.sh -- the pre-launch gate, written ONCE and sourced by every flow chain.
#
# WHY THIS FILE EXISTS
#
#   Both gates used to be copy-pasted into each *_chain.sh: six files, seven call
#   sites, three spellings of the memwatch path, and the disk floor written as a
#   bare 6 or 10 in the middle of the chain. Two copies of a threshold is two
#   chances for a chain to check a number nobody re-measured -- and the failure
#   that motivated the gates at all (a 6h55m run that died at "OOM at 60 % iter 0,
#   swap exhausted") is exactly what a drifted copy lets through. So:
#
#     * the disk floor defaults to GATE_MIN_GB here, and the one site that
#       genuinely needs another one passes it as an argument (ws_chain: its run
#       tree is on /),
#     * the memory gate is memwatch.sh --preflight, called from this one place, so
#       every chain gets the same floors, the same --need semantics and the same
#       MEM_PREFLIGHT line in its log,
#     * the refusal names itself: the gate sets GATE_REASON to DISK_LOW or
#       MEM_LOW, so a caller cannot report ABORT_MEM_LOW for a full disk,
#     * memwatch.sh is found next to this file, so there is no path to misspell.
#
#   The log shape is then the same at every site, which is what makes one grep
#   work on all of them -- DISK_GB_FREE, MEM_HEADROOM, memwatch's own
#   MEM_PREFLIGHT verdict, and, only on a refusal, the caller's ABORT_<reason>.
#
# USAGE
#
#   . $B/gate.sh
#   gate 8000 core_chain || { say "ABORT_$GATE_REASON"; exit 1; }
#   gate 8000 "grt_sweep_$ADJ" || { say "ARM_ABORT_$GATE_REASON adj=$ADJ"; return 1; }
#
#   gate NEED_MB TAG [MIN_GB] [MOUNT]
#        Both gates, in the order they have always run: disk first, then memory.
#        0 = go, 1 = refuse, and a refusal sets GATE_REASON. MOUNT defaults to
#        /home, MIN_GB to $GATE_MIN_GB. A site whose disk figure was only ever
#        reported, never a refusal, passes MIN_GB 0: 0 is never reached, so the
#        line is still logged and no new way to wedge an unattended chain appears.
#   mem_gate NEED_MB TAG [LABEL]   the memory gate alone.
#   disk_gate [MIN_GB] [MOUNT]     the disk gate alone.
#   free_gb [MOUNT]                available GB below MOUNT (default /home).
#
#   NEED_MB is the job's measured peak plus margin, not a guess: 8000 for the
#   DRT-bearing chains (the arms peak at 6.4-7.0 GB), 9000 for ws_chain (the full
#   Chip flow, and ws_flow carries no cgroup cap so the box is the only limit),
#   and for ws_synth_chain it is derived from that chain's own --memory=$CAP, so
#   the gate and the cap cannot drift apart either.
#   MEMWATCH_FORCE=1 proceeds past a memory refusal and records that it did, so a
#   conservative threshold can never wedge an unattended chain permanently.
#
#   The caller's own `say` and LOG are used, so this must be sourced after they
#   are defined; bash resolves both when the function runs, not at source time.
#
# VERIFY IT
#
#   bash build/gate_selftest.sh   -- every branch above, a check that no chain has
#   grown its own copy back, and all six chains run end to end with the box
#   stubbed to refuse. It stubs memwatch and docker, launches no real container,
#   and writes nothing outside its own temp dir (mem_audit/ included). Run it
#   after touching this file, memwatch.sh or any *_chain.sh; it exits non-zero on
#   drift and prints which contract moved.

# The memwatch this gates with is the one beside this file. Overridable so the
# gate's own branches can be exercised without touching the real audit dir.
GATE_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
MEMWATCH=${MEMWATCH:-$GATE_DIR/memwatch.sh}
GATE_MIN_GB=${GATE_MIN_GB:-6}

free_gb() { df -BG --output=avail "${1:-/home}" | tail -1 | tr -dc '0-9'; }

disk_gate() {  # disk_gate [MIN_GB] [MOUNT] -- 0 = go, 1 = refuse
  local min=${1:-$GATE_MIN_GB} mount=${2:-/home} have
  have=$(free_gb "$mount")
  say "DISK_GB_FREE $have"
  # An unreadable figure is a refusal, not a pass: `[ "" -lt 6 ]` is a bash error
  # that returns non-zero, and an `if` reads that as "enough disk", which is the
  # one answer this gate must never give by accident.
  case "${have:-}" in
    ''|*[!0-9]*) say "GATE_DISK_UNREADABLE mount=$mount"; return 1 ;;
  esac
  [ "$have" -lt "$min" ] && return 1
  return 0
}

mem_gate() {  # mem_gate NEED_MB TAG [LABEL] -- 0 = go, 1 = refuse
  local need=$1 tag=$2 label=${3:-}
  # Said, not just printed, so the state the decision was made from survives an
  # unattended run whose stdout is redirected to /dev/null.
  say "MEM_HEADROOM${label:+ $label} $(bash "$MEMWATCH" --headroom)"
  bash "$MEMWATCH" --preflight --need "$need" --tag "$tag" --log "${LOG:-}" || return 1
  return 0
}

gate() {  # gate NEED_MB TAG [MIN_GB] [MOUNT] -- 0 = go, 1 = refuse
  GATE_REASON=""
  disk_gate "${3:-$GATE_MIN_GB}" "${4:-/home}" || { GATE_REASON=DISK_LOW; return 1; }
  mem_gate "$1" "$2" || { GATE_REASON=MEM_LOW; return 1; }
  return 0
}
