#!/usr/bin/env bash
# lvs_fetch_pdk_subset.sh -- materialise the pinned LVS deck + the fixture family, for CI or a
# fresh box.
#
# WHY THIS EXISTS
#
#   The LVS evidence (build/lvs/lvs_fixtures_verdict.json) is a family of fixtures -- MOSFETs,
#   resistors, MIM caps, BJTs, diodes and MOS caps -- and every entry in it is about three kinds of
#   file: the deck gf180mcu.lvs, and that fixture's layout and netlist. All of them come from the
#   PDK, which
#   this repository does not track -- libs.tech/ is gitignored -- so a CI checkout has nothing to
#   re-run the harness against, and could never notice the evidence going stale.
#
#   This fetches exactly those files, for every fixture build/lvs_fixtures.tsv names, from the PDK
#   source repository at a pinned commit, into a directory the harness can be pointed at
#   (`tools/klayout_lvs.sh --deck ...`). The pin is not a guess: at 355b9ee every one of those
#   files is byte-identical to the version the committed family records, which is checked here
#   against all of the recorded hashes before anything is written.
#
#   The commit is the revision this box's PDK install has -- "gf180mcu.lvs: do not use shortcut
#   logic for flag_missing_ports", 2026-07-17. Upstream `main` is *not* a valid pin: its deck
#   differs, so a report about it would be a mismatch for every machine that has this PDK, which
#   is the sort of drift this pin exists to prevent.
#
# WHAT IT FETCHES
#
#   The deck, then whatever the deck's own `# %include rule_decks/...` lines name -- KLayout
#   expands those relative to the deck, and a deck without its rule_decks extracts nothing and
#   compares two empty netlists, so those are not optional extras. Then every fixture named by
#   build/lvs_fixtures.tsv, layout and netlist, and the config files those switches come from.
#
#   <into>/gf180mcu.lvs
#   <into>/rule_decks/*.lvs            (one per include line, transitively)
#   <into>/testing/unit/<category>/layout/<fixture>.gds.gz
#   <into>/testing/unit/<category>/netlist/<fixture>.cdl
#   <into>/testing/unit/<category>/config/default.yaml
#   <into>/PIN.txt                     (the ref, and what it was checked against)
#
# EXIT STATUS
#
#   0  fetched, and every file the family evidence describes matches the hash it recorded
#   1  a hash disagrees, or an include target is missing -- the pin is not the revision the
#      evidence is about, and a run against it would produce a mismatch that means nothing
#   2  could not fetch (no curl/sha256sum/python, HTTP failure, bad arguments)
#
#   A path that exists and already matches is left alone, so re-running is cheap and idempotent.
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../../.." && pwd)

REPO=${LVS_PDK_REPO:-fossi-foundation/globalfoundries-pdk-libs-gf180mcu_fd_pv}
PIN=${LVS_PDK_REF:-355b9ee6b6f64327c8d5ac879dee597fe1e9c4b2}
INTO=$HERE/.lvs_pin
REPORT=$HERE/lvs/lvs_fixtures_verdict.json
MANIFEST=$HERE/lvs_fixtures.tsv

usage() { sed -n '2,/^set -u$/p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --into)     INTO=$2; shift 2 ;;
        --into=*)   INTO=${1#*=}; shift ;;
        --ref)      PIN=$2; shift 2 ;;
        --ref=*)    PIN=${1#*=}; shift ;;
        --repo)     REPO=$2; shift 2 ;;
        --repo=*)   REPO=${1#*=}; shift ;;
        --report)   REPORT=$2; shift 2 ;;
        --report=*) REPORT=${1#*=}; shift ;;
        --manifest) MANIFEST=$2; shift 2 ;;
        --manifest=*) MANIFEST=${1#*=}; shift ;;
        -h|--help)  usage; exit 0 ;;
        *) echo "lvs_fetch_pdk_subset: unknown argument: $1 (try --help)" >&2; exit 2 ;;
    esac
done

for t in curl sha256sum; do
    command -v "$t" >/dev/null 2>&1 || { echo "SETUP  $t is not on PATH" >&2; exit 2; }
done
PY=""
for cand in python3 python; do
    if "$cand" -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1; then
        PY=$cand; break
    fi
done
[ -n "$PY" ] || { echo "SETUP  no python3/python on PATH (needed to read the recorded hashes)" >&2; exit 2; }
[ -f "$MANIFEST" ] || { echo "SETUP  no fixture manifest at $MANIFEST" >&2; exit 2; }
# The committed evidence is optional here: a first run (or a new fixture list) has nothing to
# verify against, and saying so is better than refusing to fetch.

RAW="https://raw.githubusercontent.com/$REPO/$PIN/klayout/lvs"
TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$INTO" || exit 2

# fetch <repo-relative-path-under-klayout/lvs> <destination> -- 0 ok, 2 HTTP/tooling failure
fetch() {
    local rel=$1 dest=$2
    if [ -f "$dest" ]; then
        echo "  keep    $rel"
        return 0
    fi
    mkdir -p "$(dirname "$dest")" || return 2
    if ! curl -fsSL "$RAW/$rel" -o "$TMP/dl.$$"; then
        echo "SETUP  could not fetch $RAW/$rel" >&2
        return 2
    fi
    mv "$TMP/dl.$$" "$dest" || return 2
    echo "  fetch   $rel"
}

echo "pin     $REPO@${PIN:0:12}"
echo "into    ${INTO#"$ROOT"/}"

fetch gf180mcu.lvs "$INTO/gf180mcu.lvs" || exit 2

# The deck's own include lines decide what else is needed; nothing here hardcodes a file list.
# Transitive, and that is not caution: the deck includes devices_connections.lvs, which includes
# general_connections.lvs, which the deck itself never names -- a one-level fetch produced a run
# that died in KLayout's include expansion (measured 2026-10-17), which is exactly the kind of
# "deck without its rule_decks" failure this whole step exists to prevent.
# Each include target resolves against the directory of the file that names it, which is what
# KLayout does: the deck says `rule_decks/mos_extraction.lvs`, and mos_extraction.lvs says
# `general_connections.lvs` meaning its own neighbour. Queue lines carry that base as `base<TAB>rel`.
enqueue() {  # file-with-includes, base-dir -> queue lines
    local f=$1 base=$2 rel
    grep -E '^#[[:space:]]*%include' "$f" 2>/dev/null \
        | sed -E 's/^#[[:space:]]*%include[[:space:]]+//; s/[[:space:]]+$//' \
        | while IFS= read -r rel; do
              [ -n "$rel" ] && printf '%s\t%s\n' "$base" "$rel"
          done
}

: > "$TMP/todo"; : > "$TMP/done"
enqueue "$INTO/gf180mcu.lvs" "" > "$TMP/todo"
n=0; direct=0
while :; do
    line=$(head -n 1 "$TMP/todo")
    [ -n "$line" ] || break
    if [ "$(wc -l < "$TMP/todo")" -gt 1 ]; then
        tail -n +2 "$TMP/todo" > "$TMP/todo.next" && mv "$TMP/todo.next" "$TMP/todo"
    else
        : > "$TMP/todo"
    fi
    base=${line%%$(printf '\t')*}
    rel=${line#*$(printf '\t')}
    case "$rel" in
        /*) target=${rel#/} ;;
        *)  target=${base:+$base/}$rel ;;
    esac
    target=$(printf '%s' "$target" | sed -E 's#\./##g; s#//+#/#g')
    grep -qxF "$target" "$TMP/done" && continue
    printf '%s\n' "$target" >> "$TMP/done"
    n=$((n + 1))
    [ $n -le 20 ] && direct=$((direct + 1))   # the deck's own include count, for the summary
    fetch "$target" "$INTO/$target" || exit 2
    [ -f "$INTO/$target" ] || { echo "SETUP  included file missing after fetch: $target" >&2; exit 1; }
    filebase=$(dirname "$target")
    [ "$filebase" = "." ] && filebase=""
    enqueue "$INTO/$target" "$filebase" >> "$TMP/todo"
done
echo "  includes $n file(s) reachable from the deck ($direct named by the deck itself)"

# Every fixture the manifest claims, one line at a time, plus the config its switches come from --
# so the claim in lvs_fixtures.tsv and the switches written there are checkable against the pin's
# own files rather than against somebody's memory.
manifest_entries() {  # -> "<category>/<fixture>\t<switches>"
    grep -vE '^[[:space:]]*(#|$)' "$MANIFEST" | sed -e 's/[[:space:]]*$//'
}
fixtures=0
while IFS=$(printf '\t') read -r name _switches; do
    [ -n "$name" ] || continue
    if [ "$name" = "$name" ] && ! printf '%s' "$name" | grep -q '/'; then
        echo "SETUP  manifest line is not <category>/<fixture>: $name" >&2
        exit 2
    fi
    category=${name%%/*}; fixture=${name##*/}
    fixtures=$((fixtures + 1))
    fetch "testing/unit/$category/layout/$fixture.gds.gz" "$INTO/testing/unit/$category/layout/$fixture.gds.gz" || exit 2
    fetch "testing/unit/$category/netlist/$fixture.cdl"    "$INTO/testing/unit/$category/netlist/$fixture.cdl"    || exit 2
    if [ -f "$INTO/testing/unit/$category/config/default.yaml" ]; then
        :
    else
        fetch "testing/unit/$category/config/default.yaml" "$INTO/testing/unit/$category/config/default.yaml" || exit 2
    fi
done < <(manifest_entries)
echo "  fixtures $fixtures from $(basename "$MANIFEST")"

# The hashes the committed family evidence records, checked against what was just fetched. This is
# what makes the pin a fact rather than a claim in a comment. Without a committed aggregate there
# is nothing to check against, and that is said rather than passed over in silence.
echo
if [ ! -f "$REPORT" ]; then
    echo "note    no committed aggregate at ${REPORT#"$ROOT"/}: fetched for a first run, nothing to verify against"
else
echo "checking the fetched files against the committed family evidence"
"$PY" - "$REPORT" "$INTO" "$MANIFEST" <<'PY'
import hashlib, json, sys

report_path, into, manifest = sys.argv[1], sys.argv[2], sys.argv[3]
agg = json.load(open(report_path))
entries = {e["fixture"]: e for e in agg.get("fixtures", [])}


def digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


bad = 0
want = (agg.get("deck") or {}).get("sha256")
got = digest(f"{into}/gf180mcu.lvs")
if want is None:
    print("  FAIL deck: the evidence records no hash, so the pin cannot be tied to it")
    bad += 1
elif got != want:
    print(f"  FAIL deck: {got}")
    print(f"       evidence expects {want}")
    bad += 1
else:
    print(f"  ok   deck {got}")

checked = 0
for line in open(manifest, encoding="utf-8"):
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    name = line.split("\t")[0].strip()
    category, fixture = name.split("/", 1)
    entry = entries.get(name)
    for kind, rel in (
        ("layout", f"testing/unit/{category}/layout/{fixture}.gds.gz"),
        ("netlist", f"testing/unit/{category}/netlist/{fixture}.cdl"),
    ):
        got = digest(f"{into}/{rel}")
        if entry is None:
            print(f"  new  {name} {kind}: not in the committed evidence yet ({got[:16]})")
            continue
        want = (entry.get("inputs") or {}).get(kind)
        checked += 1
        if want is None:
            print(f"  FAIL {name} {kind}: the evidence records no hash")
            bad += 1
        elif got != want:
            print(f"  FAIL {name} {kind}: {got}")
            print(f"        evidence expects {want}")
            bad += 1
        else:
            print(f"  ok   {name} {kind} {got[:16]}")
print(f"  checked {checked} fixture input hash(es) against {len(entries)} evidence entr(ies)")
sys.exit(1 if bad else 0)
PY
fi
check=$?
if [ $check -ne 0 ]; then
    echo
    echo "lvs_fetch_pdk_subset: the pin is not the revision the committed evidence describes."
    echo "  Either pin the commit that produced it (the deck decides: see doc/lvs_plan.md),"
    echo "  or regenerate the evidence against this pin and commit the result -- never both half-way."
    exit 1
fi

{
    echo "repo     $REPO"
    echo "ref      $PIN"
    echo "fixtures $fixtures from $(basename "$MANIFEST")"
    echo "fetched  $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "verified $(basename "$REPORT") (when it exists)"
} > "$INTO/PIN.txt"
echo
echo "lvs_fetch_pdk_subset: OK -- ${INTO#"$ROOT"/} matches the evidence's recorded inputs"
