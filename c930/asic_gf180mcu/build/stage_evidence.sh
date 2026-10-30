#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# stage_evidence.sh -- sourced include: what "the measurements" are, and their fingerprint.
#
# Two jobs need this answer and must not be allowed to disagree about it:
#
#   build/stage_tapeout_config.sh   reads the evidence and writes a MEASURED-STAGING block
#                                   that quotes it, with each file's md5 under the block.
#   build/stage_tapeout_watch.sh    re-runs that job whenever the evidence moves, which is
#                                   what stops the block from describing measurements that
#                                   have been superseded.
#
# A watcher with a narrower list would sit quietly while the block went stale -- the exact
# failure the pair exists to prevent -- and a wider one would re-stage on every router
# iteration. So the list lives here, once, and both scripts source it. The reading script
# must set ROOT/WS/D first.
#
# IN THE SET -- the files whose values the block quotes or decides on:
#
#   ws/probe/out*/*.log                        each repair variant's own log: base,
#                                              diode_only, jumper_only, margin0, and any
#                                              later variant's directory
#   drt_fast/verdict/die_drt_db_compare.tsv    the fast-loop cost columns, one row per arm
#                                              (build/drt_db_compare_chain.sh writes it
#                                              after EVERY arm, so a partial run is a change)
#   drt_fast/verdict/die_diode_flow_arm.md     the flow arm's report, rewritten per arm
#   ws/logs/die_diode_flow_chain.log           the flow arm's completion marker, which is
#                                              half of what "reached DetailedRouting" means
#
# DELIBERATELY OUT OF IT:
#
#   ws/logs/predrt_*.log              the router's own console: it grows by megabytes a
#                                     minute for the 14 hours an arm routes. The block quotes
#                                     it only for the in-flight arm's reference line and for
#                                     the failure reason, and those are refreshed by the next
#                                     real trigger rather than by this one.
#   the staged block itself, the state file and the history -- watching those would make the
#   watcher fire on its own output.
stage_evidence_files() {  # one existing evidence path per line
    local f
    ls -1 "$WS"/probe/out*/*.log 2>/dev/null
    for f in "$D/verdict/die_drt_db_compare.tsv" \
             "$D/verdict/die_diode_flow_arm.md" \
             "$WS/logs/die_diode_flow_chain.log"; do
        [ -f "$f" ] && printf '%s\n' "$f"
    done
    return 0
}

# The fingerprint is over (md5, path-without-ROOT-prefix) pairs, sorted, so it changes when
# a file's content changes, when a new evidence file appears, and when one disappears --
# and it does not change when a file is touched or rewritten identically.
stage_evidence_fingerprint() {
    local f
    stage_evidence_files | LC_ALL=C sort | while IFS= read -r f; do
        printf '%s  %s\n' "$(md5sum "$f" 2>/dev/null | cut -d' ' -f1)" "${f#$ROOT/}"
    done | md5sum | cut -d' ' -f1
}
