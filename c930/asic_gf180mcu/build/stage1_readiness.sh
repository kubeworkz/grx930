#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# stage1_readiness.sh -- Stage 1 host-readiness evidence for the production flow.
#
# This is the gate that must pass before Stage 2 may start. It checks the two
# memory floors and the volume floor against the host that will run the flow:
#
#   pre-DRT        12 GiB available memory
#   DRT arm         8 GiB available memory
#   flow volume    150 GiB available space
#
# It is deliberately read-only. It starts no container, synthesis, P&R, DRT, or
# RCX run, and it always writes the evidence file when the arguments and host
# probes are usable, including when the result is FAIL.
#
# The memory source is MemAvailable from /proc/meminfo. If that field is absent
# (the MSYS /proc/meminfo lacks it), the gate falls back to MemFree and labels
# the source in the record; that is conservative and still a failure if below
# the floor. The gate does not count swap as available memory.
#
# The volume must be the filesystem that will hold the run tree, not an
# arbitrary overlay. Pass the flow root on the production host, for example:
#
#   bash c930/asic_gf180mcu/build/stage1_readiness.sh \
#     --volume /home/ubuntu/grx930_ol2 \
#     --record build/production/baseline/stage1/STAGE1_READINESS.txt
#
#   --volume DIR     required; path on the volume to measure
#   --record FILE    required; evidence file to create/refresh
#   --meminfo FILE   optional; defaults to /proc/meminfo (for controlled tests)
#
# Exit: 0 = all three checks PASS; 1 = any check FAIL or unreadable; 2 = usage.
set -u

PRE_DRT_MB=12288       # 12 GiB, 1024-based and therefore conservative
DRT_ARM_MB=8192        # 8 GiB
VOLUME_GB=150

VOLUME=
RECORD=
MEMINFO=/proc/meminfo

usage() {
    cat <<'EOF'
usage: stage1_readiness.sh --volume DIR --record FILE [--meminfo FILE]

Checks and records:
  pre-DRT available memory >= 12 GiB
  DRT-arm available memory >= 8 GiB
  flow volume available     >= 150 GiB

Exit 0 only when all three pass. The record is written even on failure.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --volume)  VOLUME=${2:-}; shift 2 ;;
        --record)  RECORD=${2:-}; shift 2 ;;
        --meminfo) MEMINFO=${2:-}; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "stage1_readiness: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [ -z "$VOLUME" ] || [ -z "$RECORD" ]; then
    usage >&2
    exit 2
fi

is_num() {
    case "${1:-}" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

mem_kb() {  # mem_kb KEY: -> kB value, or empty
    awk -v key="$1" '$1 == key { print $2; exit }' "$MEMINFO" 2>/dev/null
}

mem_total_kb=$(mem_kb 'MemTotal:')
mem_free_kb=$(mem_kb 'MemFree:')
mem_available_kb=$(mem_kb 'MemAvailable:')
swap_free_kb=$(mem_kb 'SwapFree:')

memory_source=MemAvailable
available_kb=$mem_available_kb
if ! is_num "${available_kb:-}"; then
    memory_source='MemFree (MemAvailable absent; conservative fallback)'
    available_kb=$mem_free_kb
fi

available_mb=
if is_num "${available_kb:-}"; then
    available_mb=$((available_kb / 1024))
fi

disk_kb=$(df -Pk -- "$VOLUME" 2>/dev/null | awk 'NR == 2 { print $4 }')
disk_gb=
if is_num "${disk_kb:-}"; then
    disk_gb=$((disk_kb / 1048576))
fi

pre_drt=FAIL
drt_arm=FAIL
disk=FAIL
reason=

if ! is_num "${available_mb:-}"; then
    pre_drt=UNREADABLE
    drt_arm=UNREADABLE
    reason="${reason}memory_unreadable;"
else
    [ "$available_mb" -ge "$PRE_DRT_MB" ] && pre_drt=PASS
    [ "$available_mb" -ge "$DRT_ARM_MB" ] && drt_arm=PASS
    [ "$pre_drt" = PASS ] || reason="${reason}pre_drt_below_${PRE_DRT_MB}MiB;"
    [ "$drt_arm" = PASS ] || reason="${reason}drt_arm_below_${DRT_ARM_MB}MiB;"
fi

if ! is_num "${disk_gb:-}"; then
    disk=UNREADABLE
    reason="${reason}volume_unreadable;"
else
    [ "$disk_gb" -ge "$VOLUME_GB" ] && disk=PASS
    [ "$disk" = PASS ] || reason="${reason}volume_below_${VOLUME_GB}GiB;"
fi

status=FAIL
[ "$pre_drt" = PASS ] && [ "$drt_arm" = PASS ] && [ "$disk" = PASS ] && status=PASS
[ -n "$reason" ] || reason=none

record_dir=$(dirname -- "$RECORD")
if ! mkdir -p -- "$record_dir" 2>/dev/null; then
    echo "stage1_readiness: cannot create record directory: $record_dir" >&2
    exit 1
fi
tmp="${RECORD}.tmp.$$"
cleanup() { rm -f -- "$tmp"; }
trap cleanup EXIT INT TERM

{
    printf '# Stage 1 readiness gate\n'
    printf 'generated_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'host=%s\n' "$(hostname 2>/dev/null || uname -n 2>/dev/null || echo unknown)"
    printf 'platform=%s\n' "$(uname -srm 2>/dev/null || echo unknown)"
    printf 'memory_source=%s\n' "$memory_source"
    printf 'mem.total_mb=%s\n' "$([ -n "$mem_total_kb" ] && echo $((mem_total_kb / 1024)) || echo UNREADABLE)"
    printf 'mem.available_mb=%s\n' "${available_mb:-UNREADABLE}"
    printf 'mem.free_mb=%s\n' "$([ -n "$mem_free_kb" ] && echo $((mem_free_kb / 1024)) || echo UNREADABLE)"
    printf 'mem.swapfree_mb=%s\n' "$([ -n "$swap_free_kb" ] && echo $((swap_free_kb / 1024)) || echo UNREADABLE)"
    printf 'mem.pre_drt_need_mb=%s\n' "$PRE_DRT_MB"
    printf 'mem.pre_drt=%s\n' "$pre_drt"
    printf 'mem.drt_arm_need_mb=%s\n' "$DRT_ARM_MB"
    printf 'mem.drt_arm=%s\n' "$drt_arm"
    printf 'disk.volume=%s\n' "$VOLUME"
    printf 'disk.available_gb=%s\n' "${disk_gb:-UNREADABLE}"
    printf 'disk.need_gb=%s\n' "$VOLUME_GB"
    printf 'disk=%s\n' "$disk"
    printf 'status=%s\n' "$status"
    printf 'reason=%s\n' "$reason"
} > "$tmp" || {
    echo "stage1_readiness: cannot write record: $RECORD" >&2
    exit 1
}

mv -f -- "$tmp" "$RECORD" || {
    echo "stage1_readiness: cannot replace record: $RECORD" >&2
    exit 1
}
trap - EXIT INT TERM

cat -- "$RECORD"
if [ "$status" = PASS ]; then
    echo 'STAGE1_READINESS PASS -- all three floors are met'
    exit 0
fi
echo "STAGE1_READINESS FAIL -- $reason" >&2
exit 1
