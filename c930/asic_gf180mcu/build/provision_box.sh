#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# provision_box.sh -- bring a fresh Ubuntu box to the state the chains assume.
#
# On the box itself, with no checkout and no scp (the repo is public and this
# script clones what it needs):
#
#   curl -fsSL https://raw.githubusercontent.com/kubeworkz/grx930/npu/shim-tile-model/c930/asic_gf180mcu/build/provision_box.sh \
#     | bash -s -- --branch npu/shim-tile-model
#
# The URL's branch is only where the *script* is read from.  The branch it
# deploys defaults to main, so pass --branch when the box has to match the work
# in flight -- which is the usual reason to provision one.
#
# Or from a checkout, when the box has no route to GitHub:
#
#   scp build/provision_box.sh box:/tmp/ && ssh box 'bash /tmp/provision_box.sh'
#
# What "the state the chains assume" is, in the order they need it:
#
#   0. a host that can run the precheck image        -- see the arch gate below
#   1. docker, usable by this user with no sudo      -- every chain is a docker run
#   2. ghcr.io/wafer-space/gf180mcu-precheck         -- toolchain *and* the PDK
#   3. ghcr.io/efabless/openlane2:2.3.10             -- the librelane runs
#   4. the repo deployed at $ROOT such that -v $ROOT:/work lands on ws/ and build/
#   5. one smoke test that proves 1-4 *together*, not four checks that each pass
#      on their own
#
# The PDK is not a separate install.  It is baked into the precheck image at
# /workspace/gf180mcu (PDK_ROOT/PDK are set in the image environment), which is
# why the old box has an empty ~/.ciel and 13.6 GB of image: the 3.5 GB PDK and
# the nix toolchain travel with it.  Pulling the image is the PDK install.
#
# The tools are only on PATH through the image's dev-shell entrypoint, so the
# smoke test runs `docker run IMG bash -lc ...` and never `--entrypoint bash`:
# overriding the entrypoint loses the nix profile and reports yosys as missing
# on a box that is in fact complete.
#
# It is idempotent.  Images already present are not pulled again without
# --refresh; the deploy copy overwrites the tree but never deletes, so runs/ and
# logs/ from a previous arm survive a re-provision.
#
# It deliberately never runs sudo.  If docker is unusable as this user it stops
# and prints the one command a human has to run.  The failure a silent sudo
# hides is a box that looked provisioned and then died at 3 a.m. inside the
# first docker run of an unattended arm.
set -euo pipefail

ROOT=${ROOT:-$HOME/grx930_ol2}
SRC=${SRC:-$HOME/grx930}
BRANCH=${BRANCH:-main}
REPO=${REPO:-https://github.com/kubeworkz/grx930.git}
IMG=${IMG:-ghcr.io/wafer-space/gf180mcu-precheck:latest}
IMG2=${IMG2:-ghcr.io/efabless/openlane2:2.3.10}
LIB=/workspace/gf180mcu/gf180mcuD/libs.ref/gf180mcu_fd_sc_mcu7t5v0/lib/gf180mcu_fd_sc_mcu7t5v0__tt_025C_5v00.lib

# 21 GB of images plus the PDK unpacked plus one run tree; a box below this
# would pull for twenty minutes and then be unable to start an arm.
MIN_FREE_GB=${MIN_FREE_GB:-50}

REFRESH=0
SKIP_IMAGES=0
LOCAL_IMAGE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --root)        ROOT=$2; shift 2 ;;
        --src)         SRC=$2; shift 2 ;;
        --branch)      BRANCH=$2; shift 2 ;;
        --refresh)     REFRESH=1; shift ;;
        --skip-images) SKIP_IMAGES=1; shift ;;
        --local-image) LOCAL_IMAGE=1; shift ;;
        # Piped in (curl | bash) there is no script file for $0 to point at, so
        # the usage text is a heredoc rather than a sed over the header.
        -h|--help)
            cat <<'USAGE'
usage: provision_box.sh [--root DIR] [--src DIR] [--branch B] [--refresh] [--skip-images] [--local-image]

  --root DIR      deploy target, mounted as /work (default: $HOME/grx930_ol2)
  --src DIR       checkout to clone or fetch (default: $HOME/grx930)
  --branch B      branch to deploy (default: main)
  --refresh       re-pull the images even if they are already present
  --skip-images   never pull; fail if an image is missing
  --local-image   $IMG was built on this host and is in no registry: never pull
                  it, and let its own architecture decide the arch gate

Log goes to $ROOT/logs/provision.log; the last line is PROVISION_OK or PROVISION_FAIL.
USAGE
            exit 0 ;;
        *)             echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

mkdir -p "$ROOT/logs"
LOG=$ROOT/logs/provision.log
say() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$LOG"; }
fail() { say "PROVISION_FAIL $*"; exit 1; }

say "PROVISION_START root=$ROOT branch=$BRANCH"
say "host: cores=$(nproc) mem=$(awk '/MemTotal/{printf "%.0fG", $2/1048576}' /proc/meminfo) disk=$(df -Pk "$ROOT" | awk 'NR==2{printf "%.0fG total, %.0fG free", $2/1048576, $4/1048576}')"

# ---- 0. architecture --------------------------------------------------------
# The published precheck image is linux/amd64 only: every tag in the registry
# index is amd64 plus an attestation entry, with no arm64 anywhere.  That used
# to make any non-x86_64 host a dead end, checked before docker was touched
# because "wrong machine" is worth saying plainly rather than two minutes into
# a pull.  It is no longer a dead end: the image builds from this repo's own
# Dockerfile on arm64 in about a quarter of an hour (tools/gf180mcu-precheck),
# so the gate asks what the image on this box *is* and whether it can execute
# here -- not what the host's uname says.
#
# A local tag has no registry counterpart, so --local-image keeps it out of the
# pull path entirely: `docker pull gf180mcu-precheck:arm64` fails after the
# disk check has already promised room, and --refresh would turn that into a
# failed provision on a box whose image is sitting right there.
case "$(uname -m)" in
    x86_64)        HOST_ARCH=amd64 ;;
    aarch64|arm64) HOST_ARCH=arm64 ;;
    *)             HOST_ARCH=$(uname -m) ;;
esac

if docker image inspect "$IMG" >/dev/null 2>&1; then
    IMG_ARCH=$(docker image inspect -f '{{.Architecture}}' "$IMG")
    if [ -z "$IMG_ARCH" ]; then
        # An absent field is not evidence of the wrong architecture: docker 29's
        # containerd store leaves it empty for anything pulled with --platform.
        # Refusing here would reject a correct box, so the smoke test -- which
        # has to execute the image -- stays the thing that decides.
        say "arch: $HOST_ARCH (image records no architecture; trusting the local build)"
    else
        [ "$IMG_ARCH" = "$HOST_ARCH" ] \
            || fail "arch-mismatch: $IMG is linux/$IMG_ARCH and this host is $HOST_ARCH, so it cannot execute here (build one for this host: tools/gf180mcu-precheck)"
        say "arch: $HOST_ARCH (local image $IMG is linux/$IMG_ARCH)"
    fi
else
    # Nothing local to inspect.  The published tag is amd64, so an amd64 host
    # can pull it; any other host is told to build first, before docker spends
    # fifteen minutes pulling an image it cannot execute.
    [ "$LOCAL_IMAGE" = 0 ] \
        || fail "image-missing: --local-image says $IMG was built here, but it is not in the local store"
    [ "$HOST_ARCH" = "amd64" ] \
        || fail "arch-unsupported: $HOST_ARCH -- $IMG ships linux/amd64 only (no arm64 in any tag). Build one for this host and pass --local-image: tools/gf180mcu-precheck"
    say "arch: $HOST_ARCH"
fi

# ---- 1. docker, without sudo ------------------------------------------------
# The chains call `docker` bare.  Testing it here is the whole point: this is the
# one dependency whose absence is not visible until the first chain starts.
command -v docker >/dev/null 2>&1 \
    || fail "docker-absent: no docker binary on PATH. Install it, then re-run: curl -fsSL https://get.docker.com | sh"
DOCKER_ERR=$(docker info 2>&1 >/dev/null | head -2) \
    || fail "docker-unusable: docker is installed but this user cannot reach the daemon ($DOCKER_ERR). A human runs: sudo usermod -aG docker \$USER && newgrp docker"
say "docker: $(docker --version | sed 's/Docker version //'), root=$(docker info --format '{{.DockerRootDir}}')"

# ---- 2. headroom ------------------------------------------------------------
# The 21 GB is only needed to *pull*.  A box that already carries both images
# needs room for a run tree and nothing else, so a re-provision (the idempotent
# case) is not held to the cold-start floor and cannot fail on a box that is in
# fact ready.
PENDING=0
for ref in "$IMG" "$IMG2"; do
    if [ "$REFRESH" = 1 ] || ! docker image inspect "$ref" >/dev/null 2>&1; then
        PENDING=$((PENDING + 1))
    fi
done
NEED_GB=5
[ "$PENDING" -gt 0 ] && NEED_GB=$MIN_FREE_GB
FREE_GB=$(df -Pk "$ROOT" | awk 'NR==2{printf "%d", $4/1048576}')
[ "$FREE_GB" -ge "$NEED_GB" ] \
    || fail "disk-low: ${FREE_GB}G free under $ROOT, need ${NEED_GB}G ($PENDING image(s) to pull)"
say "disk: ${FREE_GB}G free (floor ${NEED_GB}G, ${PENDING} image(s) pending)"

# ---- 3. images --------------------------------------------------------------
pull() {
    local ref=$1 t0 t1
    if [ "$LOCAL_IMAGE" = 1 ] && [ "$ref" = "$IMG" ]; then
        say "local image, never pulled: $ref (linux/${IMG_ARCH:-arch-unrecorded})"
        return 0
    fi
    if [ "$REFRESH" = 0 ] && docker image inspect "$ref" >/dev/null 2>&1; then
        say "image present, not pulling: $ref ($(docker images --format '{{.Size}}' "$ref" | head -1))"
        return 0
    fi
    [ "$SKIP_IMAGES" = 1 ] && { say "image missing and --skip-images given: $ref"; return 1; }
    t0=$(date +%s)
    docker pull --quiet "$ref" >>"$LOG" 2>&1 \
        || fail "pull-failed: $ref (see $LOG)"
    t1=$(date +%s)
    say "pulled $ref in $((t1 - t0))s"
    return 0
}
pull "$IMG"  || fail "image-missing: $IMG"
pull "$IMG2" || fail "image-missing: $IMG2"

# ---- 3b. can the librelane image actually start here? ------------------------
# openlane2 is multi-arch (an arm64 box pulls linux/arm64 and runs openroad
# natively), but the precheck image is not published for arm64 at all -- so a
# host can hold both images and be able to execute only one of them.  That box
# is not unprovisioned and it is not ready for a flow arm either, and saying
# PROVISION_OK without saying which of the two it is produces exactly the box
# this script exists to prevent: one that looks complete until the first chain
# dies in it.  Reported, not fatal, and carried in the final line so a caller
# can grep for librelane=ok.
LIBRELANE_ARCH=$(docker image inspect -f '{{.Architecture}}' "$IMG2" 2>/dev/null || echo unknown)
LIBRELANE=ok
[ -n "$LIBRELANE_ARCH" ] || LIBRELANE=arch-unrecorded
if [ -n "$LIBRELANE_ARCH" ] && [ "$LIBRELANE_ARCH" != "$HOST_ARCH" ]; then
    LIBRELANE="unusable:linux/$LIBRELANE_ARCH-on-$HOST_ARCH"
    say "librelane: $IMG2 is linux/$LIBRELANE_ARCH and this host is $HOST_ARCH, so the image cannot start here and no flow arm can run on this box. A binfmt handler would emulate it (slowly); a host of the matching architecture is the real fix."
fi

# ---- 4. repo ----------------------------------------------------------------
# The checkout is kept at $SRC and only c930/asic_gf180mcu/ is deployed to $ROOT,
# because that is what the mount expects: -v $ROOT:/work must put ws/ and build/
# at /work/ws and /work/build.
if [ -d "$SRC/.git" ]; then
    [ -z "$(git -C "$SRC" status --porcelain)" ] \
        || fail "dirty-checkout: $SRC has local changes; refusing to reset it. Commit or stash, or pass --src pointing at a clean clone"
    git -C "$SRC" fetch --depth 1 origin "$BRANCH" >>"$LOG" 2>&1 \
        || fail "git-fetch-failed: $BRANCH from $REPO"
    git -C "$SRC" checkout -q -B "$BRANCH" FETCH_HEAD >>"$LOG" 2>&1
else
    rm -rf "$SRC"
    git clone --quiet --depth 1 --branch "$BRANCH" "$REPO" "$SRC" >>"$LOG" 2>&1 \
        || fail "git-clone-failed: $BRANCH from $REPO"
fi
[ -d "$SRC/c930/asic_gf180mcu/ws" ] || fail "repo-layout: $SRC/c930/asic_gf180mcu/ws not found after checkout"
say "repo: $(git -C "$SRC" rev-parse --short HEAD) on $BRANCH ($SRC)"

mkdir -p "$ROOT"
cp -a "$SRC/c930/asic_gf180mcu/." "$ROOT/" || fail "deploy-copy-failed: $SRC/c930/asic_gf180mcu -> $ROOT"
say "deployed: $ROOT ($(du -sh "$ROOT" 2>/dev/null | cut -f1))"

# ---- 5. smoke test ----------------------------------------------------------
# Not "is yosys installed" -- a counter that has to reach real gf180mcu cells.
# That single run exercises the entrypoint's PATH, the PDK, the liberty file and
# the mount, which are four separate ways to be half-provisioned.
SMOKE_DIR=$(mktemp -d /tmp/provision_smoke.XXXXXX)
trap 'rm -rf "$SMOKE_DIR"' EXIT

cat > "$SMOKE_DIR/smoke.v" <<'VERILOG'
module smoke(input clk, input rst_n, output reg [3:0] q);
  always @(posedge clk or negedge rst_n)
    if (!rst_n) q <= 4'd0;
    else        q <= q + 4'd1;
endmodule
VERILOG

cat > "$SMOKE_DIR/smoke.sh" <<EOF
set -e
test -f "$LIB" || { echo SMOKE_NOLIB; exit 3; }
yosys -p 'read_verilog /pv/smoke.v; synth -top smoke -noabc; dfflibmap -liberty $LIB; abc -liberty $LIB -fast; clean; stat' 2>&1
echo "--- entrypoints"
for s in /work/ws/die_predrt_exec.sh /work/build/gate.sh /work/build/drt_disk_guard.sh; do
  if [ -f "\$s" ]; then echo "ENTRY_OK \$s"; else echo "ENTRY_MISSING \$s"; fi
done
echo "--- versions"
printf 'openroad '; openroad -version 2>&1 | head -1
EOF

SMOKE=$(docker run --rm -v "$SMOKE_DIR:/pv:ro" -v "$ROOT:/work" "$IMG" bash -lc 'bash /pv/smoke.sh' 2>&1) \
    || fail "smoke-run-failed: $(printf '%s' "$SMOKE" | tail -3 | tr '\n' ' ')"
printf '%s\n' "$SMOKE" >> "$LOG"

printf '%s\n' "$SMOKE" | grep -q SMOKE_NOLIB && fail "smoke-nolib: liberty not found at $LIB inside $IMG"

# yosys 0.66 prints the histogram as "      18 cells"; older builds print
# "Number of cells:  18".  Accept both: pinning the parser to the image's yosys
# build would turn a rebuilt image into a failed provision on a good box, which
# is the opposite of what this script is for.
CELLS=$(printf '%s\n' "$SMOKE" | awk '/^[ \t]+[0-9]+ cells$/{c=$1} /Number of cells:/{c=$NF} END{print c+0}')
MAPPED=$(printf '%s\n' "$SMOKE" | awk '/^[ \t]+[0-9]+[ \t]+gf180mcu_fd_sc_mcu7t5v0__/{s+=$1} END{print s+0}')
[ "$CELLS" -ge 4 ] \
    || fail "smoke-not-mapped: stat reported '${CELLS}' cells, expected >=4"
[ "$MAPPED" -ge 4 ] \
    || fail "smoke-not-gf180: ${MAPPED} gf180mcu cells in the netlist, expected >=4"

for s in /work/ws/die_predrt_exec.sh /work/build/gate.sh; do
    printf '%s\n' "$SMOKE" | grep -qF "ENTRY_OK $s" || fail "smoke-entry-missing: $s"
done
say "smoke: 4-bit counter -> ${CELLS} cells (${MAPPED} gf180mcu), entrypoints present"

say "PROVISION_OK images=2 librelane=$LIBRELANE cells=$CELLS root=$ROOT"
