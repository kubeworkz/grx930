#!/bin/bash
# retire_volume_swap.sh -- remove the redundant swapfile on the Hetzner volume.
#
# WHY (measured 2026-10-12, flow box ubuntu@49.13.6.8)
#
#   The box runs FOUR swapfiles -- 4 + 8 + 8 GiB on the root disk and 8 GiB on
#   the volume -- i.e. 28 GiB of swap for 15.25 GiB of RAM. The volume's is the
#   LOWEST priority (-5) and held 196 kB, so the kernel only touches it after the
#   other 20 GiB are already gone: it cannot rescue a run the other three could
#   not. Meanwhile it occupies 40 % of a 20 GiB volume that is useful precisely
#   as archive space (it holds the compressed old-campaign run).
#
#   The counter-argument is on the record: PLAN_B_netlist_rework.md documents
#   "OOM at 60 % iter 0, swap exhausted" on this box, which is why swap kept
#   being added. That is why this script refuses to act unless 16 GiB of OTHER
#   swap remains and the file is essentially unused -- it will not quietly lower
#   the box's worst-case headroom below 15.25 GiB RAM + 16 GiB swap.
#
#   Reversible: the file is regenerated with fallocate/mkswap and the fstab line
#   restored, and a backup of /etc/fstab is kept.
#
# USAGE (needs root: swapoff, /etc/fstab, and a root-owned file)
#
#   bash retire_volume_swap.sh            # report only -- changes nothing
#   sudo bash retire_volume_swap.sh --apply
#
# Also, at the end, creates a writable archive directory on the volume, because
# the freed space is not usable by the flow user until the root-owned volume has
# one directory owned by that user.
set -u
VOL=/mnt/HC_Volume_106967865
SW=$VOL/swapfile
APPLY=${1:-}
MIN_OTHER_SWAP_KB=$((16 * 1024 * 1024))   # 16 GiB must remain elsewhere
MAX_USED_KB=$((64 * 1024))                # refuse if this file is really in use
say() { printf '  %s\n' "$*"; }
die() { printf 'ABORT: %s\n' "$*" >&2; exit 1; }

echo "=== 1. preconditions ==="
[ "$(id -u)" = 0 ] || [ "$APPLY" != "--apply" ] || die "not root -- run: sudo bash $0 --apply"
findmnt -no SOURCE,TARGET "$VOL" >/dev/null 2>&1 || die "$VOL is not mounted"
[ -b "$(findmnt -no SOURCE "$VOL")" ] || die "$VOL is not on a block device"
say "volume mounted: $(findmnt -no SOURCE "$VOL") -> $VOL"

# Is it actually the volume's swapfile, and is it in use?
in_swaps=$(grep -c "^$SW " /proc/swaps || true)
if [ "$in_swaps" = 1 ]; then
  used=$(awk -v f="$SW" '$1==f {print $4}' /proc/swaps)
  size=$(awk -v f="$SW" '$1==f {print $3}' /proc/swaps)
  say "active swap: yes -- size $((size/1024)) MiB, in use $((used/1024)) MiB"
  [ "$used" -le "$MAX_USED_KB" ] || die "in use ($((used/1024)) MiB > $((MAX_USED_KB/1024)) MiB); something relies on it -- retry when the box is idle"
else
  say "active swap: no (already retired, or was never activated this boot)"
fi

other=$(awk -v f="$SW" 'NR>1 && $1!=f {s+=$3} END {print s+0}' /proc/swaps)
say "swap remaining elsewhere: $((other/1024)) MiB"
if [ "$(awk -v f="$SW" 'NR>1 && $1!=f {n++} END {print n+0}' /proc/swaps)" -lt 1 ]; then
  die "no other swapfile would remain -- this file is the box's only swap"
fi
[ "$other" -ge "$MIN_OTHER_SWAP_KB" ] || die "only $((other/1024)) MiB of other swap; policy needs >= 16384 MiB"
say "policy check: OK (>= 16 GiB stays on the local disk)"

if [ "$APPLY" != "--apply" ]; then
  echo
  echo "REPORT ONLY. Would: swapoff $SW; rm it; comment its /etc/fstab line;"
  echo "  mkdir -p $VOL/archive and chown it to uid ${SUDO_UID:-$(id -u)}:${SUDO_GID:-$(id -g)};"
  echo "  back up /etc/fstab to /etc/fstab.pre-swapretire."
  echo "Re-run with: sudo bash $0 --apply"
  exit 0
fi

echo
echo "=== 2. retire it ==="
cp -f /etc/fstab /etc/fstab.pre-swapretire && say "backed up /etc/fstab -> /etc/fstab.pre-swapretire"
if [ "$in_swaps" = 1 ]; then
  swapoff "$SW" || die "swapoff failed (insufficient free RAM to pull it back in?) -- nothing else was changed"
  say "swapoff done"
fi
rm -f "$SW" && say "removed $SW"
if grep -q "^$SW" /etc/fstab; then
  sed -i "s|^$SW|#&|" /etc/fstab && say "commented the fstab line"
  grep -n "$SW" /etc/fstab | sed 's/^/    /'
else
  say "fstab line already commented or absent"
fi
systemctl daemon-reload 2>/dev/null && say "systemctl daemon-reload"

echo
echo "=== 3. make the freed space usable by the flow user ==="
mkdir -p "$VOL/archive" && chown "${SUDO_UID:-0}:${SUDO_GID:-0}" "$VOL/archive" \
  && say "created $VOL/archive owned by ${SUDO_UID:-0}:${SUDO_GID:-0}" \
  || say "could not create $VOL/archive"

echo
echo "=== 4. verify ==="
echo "  /proc/swaps now:"; sed 's/^/    /' /proc/swaps
if grep -q "^$SW" /proc/swaps; then echo "  !! the file is still active -- investigate"; else say "the volume swapfile is gone from /proc/swaps"; fi
df -h "$VOL" | sed 's/^/  /'
free -h | sed 's/^/  /'
say "archive dir writable: $( [ -w "$VOL/archive" ] && echo yes || echo 'no -- chown it' )"
echo
echo "To undo: sudo fallocate -l 8G $SW && sudo mkswap $SW && sudo swapon $SW && uncomment the fstab line (backup at /etc/fstab.pre-swapretire)"
