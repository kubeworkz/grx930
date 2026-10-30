#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""precheck_verdict.py -- read a wafer.space gf180mcu precheck run and state the verdict in JSON.

Why this exists
---------------
The precheck is the gate between this design and a wafer.space slot, and its verdict is not its
exit code: the run container exits **0** even when the flow fails (the CLI does call
`sys.exit(1)` after `err(...)`, but the image's wrapper scripts do not propagate it -- the
container that failed the template run, `ws-precheck2`, is recorded as `Exited (0)`). The verdict
lives only in the log text, in two different shapes, plus the per-step `state_in.json` metrics and
the per-check report JSONs. This tool reads those and prints one JSON object CI can branch on,
with a process exit code that matches: **0** all blocking gates passed, **1** a blocking gate
failed, **2** the run aborted before the end (incomplete -- not certifiable either way), **3** no
verdict could be parsed, **4** usage or IO error.

The gate semantics are taken from the precheck's own source (`precheck.py` in the image,
`ghcr.io/wafer-space/gf180mcu-precheck`, read 2026-10-16):

* the flow is 16 steps; with `--cob` a `KLayout.CheckPadMask` step is substituted in after
  `KLayout.CheckSize`, giving 17. Its failure is an ordinary step failure: it aborts the flow;
* `Checker.KLayoutDensity` and `Checker.KLayoutDRC` are *deferred* checkers: the flow runs to the
  end and reports them together as `One or more deferred errors were encountered:`;
* `CheckerKLayoutZeroAreaPolygons` is `deferred = False` with
  `ERROR_ON_KLAYOUT_ZERO_AREA_POLYGONS` defaulting to True, so it aborts the flow where it sits;
* `ERROR_ON_MAGIC_DRC: False` is set by the precheck itself, so Magic DRC errors are a **metric,
  never a gate** -- reported at WARNING level, never in the deferred list;
* the KLayout DRC *deck* gates on its total, but one family inside it is advisory: the `*_OFFGRID`
  rules (geometry off the 5 nm manufacturing grid) are wafer.space's critical warning, not a hard
  blocker (ruled 2026-10-16). See ADVISORY_RULE_SUFFIXES for how that is subtracted.

So a PASS is: the flow reached `KLayout.WriteLayout`, the deferred list is empty, and no blocking
check reported errors. Warnings (Magic DRC, and the advisory rule families) are kept in the JSON
but do not decide it.

Usage
-----
    python3 tools/precheck_verdict.py --log /path/precheck_ws.log
    python3 tools/precheck_verdict.py --run-dir /path/to/run2 --out verdict.json
    python3 tools/precheck_verdict.py --log log --run-dir run_dir    # best: log + metrics/reports

With `--run-dir` the tool also picks up, when present:
* the run's `flow.log` (the authoritative step order, including `Skipping step '...'` lines);
* every `*/state_in.json` / `state_out.json` metrics dict (last step wins) -> `metrics`;
* the per-check report JSONs (`density.klayout.json`, `antenna.klayout.json`, `drc.klayout.json`)
  -> per-gate `rules` tallies, which is what makes a failure count actionable.

The log's rich-formatted output is wrapped at ~80 columns, so one message can be split across
several physical lines; the parser re-joins continuations before matching (see `load_records`).
Timestamps carry no date, so durations use a day-rollover counter, and the run date is taken from
the subprocess lines that do have one.

Stdlib only, so it runs wherever the repo does (Git Bash, CI, the flow box).
"""

import argparse
import glob
import json
import os
import re
import sys
import time

SCHEMA = "grx930.precheck-verdict/1"

EXIT_PASS = 0
EXIT_GATE_FAILURE = 1
EXIT_INCOMPLETE = 2
EXIT_UNPARSED = 3
EXIT_USAGE = 4

# The flow definition, from precheck.py's PrecheckFlow.Steps (plus the --cob substitution).
EXPECTED_STAGES = [
    "Read the Layout",
    "Check Top-Level Name",
    "Check Slot Size",
    "Check Pad Mask",                 # only with --cob
    "Generate ID",
    "Render Image (w/ KLayout)",
    "Density Check",
    "KLayout Density Checker",
    "Find Zero Area Polygons",
    "KLayout Zero Area Polygons Checker",
    "Antenna Check",
    "KLayout Antenna Checker",
    "Design Rule Checks",
    "Magic Design Rule Checker",
    "Design Rule Check (KLayout)",
    "KLayout Design Rule Checker",
    "Write the Layout",
]

# (key, label, blocking, keywords matched against the checker's own wording).
# blocking=False only for Magic DRC, because the precheck sets ERROR_ON_MAGIC_DRC: False.
GATES = (
    ("density", "KLayout density", True, ("density",)),
    ("zero_area", "KLayout zero area polygons", True, ("zero area",)),
    ("antenna", "KLayout antenna", True, ("antenna",)),
    ("magic_drc", "Magic DRC", False, ("magic",)),
    ("klayout_drc", "KLayout DRC", True, ("klayout drc", "drc")),
)
BLOCKING = {key: blocking for key, _label, blocking, _kw in GATES}
LABELS = {key: label for key, label, _b, _kw in GATES}

# Rule families wafer.space reports but does not block on. The precheck runs one KLayout DRC deck
# and gates on its total, so the family has to be subtracted here for a count to mean what the
# submitters are told it means:
#   * `*_OFFGRID` is emitted by the PDK deck's own `if OFFGRID` block (`rule_decks/geom.drc`,
#     `poly2.ongrid(0.005)` and friends), enabled by the PDK default `offgrid true` -- which the
#     precheck does not override, since its KLAYOUT_DRC_OPTIONS carry only decks/variant/workers;
#   * on the template artifact it is 71,575 of the 83,777 items (85.4 %), and wafer.space rules it
#     a critical warning rather than a hard blocker (2026-10-16).
# The split is applied only to what a per-rule tally accounts for, and only in --run-dir mode: the
# log alone says how many items there are, not which rules fired, so without a tally the count
# stays blocking and stays conservative.
ADVISORY_RULE_SUFFIXES = ("_OFFGRID",)


def is_advisory_rule(rule):
    """True for a rule name in an advisory family, e.g. metal1_OFFGRID / contact_OFFGRID."""
    return str(rule).upper().endswith(ADVISORY_RULE_SUFFIXES)


def advisory_tally(rules):
    """(advisory, listed) counts from a per-rule tally.

    `listed` is what the tally itself accounts for, so a truncated report -- a top-15 slice, or a
    hand-recovered file -- is detectable by the caller and cannot be read as an exhaustive one.
    """
    rules = rules or {}
    return (sum(count for rule, count in rules.items() if is_advisory_rule(rule)),
            sum(rules.values()))

TS_RE = re.compile(r"^\[(\d\d):(\d\d):(\d\d)\]\s+(VERBOSE|INFO|WARNING|ERROR|CRITICAL|DEBUG)\s+(.*)$")
FILE_REF_RE = re.compile(r"\s+([A-Za-z0-9_./-]+\.py:\d+)\s*$")
BANNER_RE = re.compile(r"^[\u2500-\u257F-]{5,}\s*(.+?)\s*[\u2500-\u257F-]{5,}$")
PROGRESS_RE = re.compile(r"Stage\s+(\d+)\s+-\s+(.+?)\s*[\u2501\u2500-]+\s+(\d+)\s*/\s*(\d+)\s+(\S+)\s*$")
STEP_RE = re.compile(r"Running\s+'([A-Za-z0-9_.]+)'\s+at\s+'([^']+)'")
SKIP_RE = re.compile(r"Skipping step\s+'([^']+)'")
# rich wraps this line mid-hash, so the 64 hex characters may be split by whitespace
SHA_RE = re.compile(r"SHA256 for\s+(\S+):\s*((?:[0-9a-fA-F]\s*){64})")
TAG_RE = re.compile(r"with the tag\s+'([^']+)'")
COUNT_RE = re.compile(
    r"^(?P<count>\d+)\s+(?P<what>.+?)\s+errors?\s+found\.?(?P<deferred>\s*-\s*deferred\s*)?$")
CLEAR_RE = re.compile(r"^Check for\s+(?P<what>.+?)\s+clear\.?$", re.I)
DEFERRED_RE = re.compile(r"One or more deferred errors were encountered:\s*(?P<list>.*)$", re.S)
INLINE_RE = re.compile(r"(?P<stage>[A-Z][A-Za-z0-9 ()/'.-]+?):\s*subprocess\s*\((?P<rc>-?\d+)\s*,")
DATE_RE = re.compile(r"(\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)\s*\+0000")
DEFERRED_ITEM_RE = re.compile(r"(\d+)\s+([A-Za-z][\w /]*?)\s+errors?\s+found\.?")

HEADER_EQ = ("PDK_ROOT", "PDK")
HEADER_COLON = ("top_cell", "die_id", "cob", "slot", "threads", "workers")


def strip_ansi(text):
    return re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", text)


def gate_for(what):
    text = (what or "").lower()
    for key, _label, _blocking, keywords in GATES:
        if any(kw in text for kw in keywords):
            return key
    return None


def verdict_fails(verdict, advisory=0):
    """A verdict decides the run only if the gate blocks and has non-advisory violations.

    Magic DRC is a metric; an advisory family (_OFFGRID) is a warning, so a gate whose whole count
    is advisory does not fail. `advisory` is how many of the gate's items the per-rule tally
    attributed to those families -- 0 when no tally was available, which keeps it conservative.
    """
    if verdict["count"]:
        if not BLOCKING.get(verdict["gate"], True):
            return False
        return (verdict["count"] - advisory) > 0
    return verdict["level"] == "ERROR"


def fmt_clock(total):
    if total is None:
        return None
    return "%02d:%02d:%02d" % ((total // 3600) % 24, (total // 60) % 60, total % 60)


def load_records(path):
    """Read the log into logical records, re-joining rich's wrapped continuations.

    A continuation is a physical line with leading whitespace whose predecessor was a
    timestamped log line; banners and progress lines have no leading whitespace, so they start
    records of their own.
    """
    records = []
    meta = {"first_date": None, "clock_start": None, "clock_end": None, "wrap_joins": 0,
            "wall_seconds": None}
    day = 0
    prev_sod = None
    # The log is UTF-8 (the stage banners are box-drawing characters in U+2500-U+257F), so it
    # must be read as UTF-8 explicitly: on a platform whose default encoding is not UTF-8 the
    # banners decode to mojibake and no stage is ever recognised.
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        for raw in handle:
            line = strip_ansi(raw.rstrip("\r\n")).replace("\x00", "")
            if not line.strip():
                continue
            match = TS_RE.match(line)
            if not match:
                if line[:1] in (" ", "\t") and records and records[-1]["level"]:
                    records[-1]["msg"] += " " + line.strip()
                    meta["wrap_joins"] += 1
                    continue
                records.append({"line_no": len(records), "clock_total": None, "clock_text": None,
                                "level": None, "msg": line.strip(), "raw": line})
                # the log's own lines carry no date; the subprocess lines echoed into it do
                if meta["first_date"] is None:
                    date = DATE_RE.search(line)
                    if date:
                        meta["first_date"] = date.group(0).replace(" +0000", "")
                continue
            hour, minute, second = (int(match.group(i)) for i in (1, 2, 3))
            sod = hour * 3600 + minute * 60 + second
            if prev_sod is not None and sod < prev_sod - 12 * 3600:
                day += 1
            prev_sod = sod
            msg = match.group(5)
            ref = FILE_REF_RE.search(msg)
            if ref:
                msg = msg[:ref.start()].rstrip()
            records.append({"line_no": len(records), "clock_total": day * 86400 + sod,
                            "clock_text": "%02d:%02d:%02d" % (hour, minute, second),
                            "level": match.group(4), "msg": msg.strip(), "raw": line})
            date = DATE_RE.search(line)
            if date and not meta["first_date"]:
                meta["first_date"] = date.group(0).replace(" +0000", "")
            if meta["clock_start"] is None:
                meta["clock_start"] = records[-1]["clock_total"]
            meta["clock_end"] = records[-1]["clock_total"]

    if meta["clock_start"] is not None and meta["clock_end"] is not None:
        meta["wall_seconds"] = meta["clock_end"] - meta["clock_start"]
    for rec in records:
        rec["elapsed"] = (None if rec["clock_total"] is None or meta["clock_start"] is None
                          else rec["clock_total"] - meta["clock_start"])
    return records, meta


def parse_log(records, meta):
    """Turn records into header, steps, skips, checker verdicts and the failure block."""
    parsed = {"header": {}, "artifact": {}, "steps": [], "skips": [], "banners": [],
              "progress": None, "verdicts": [], "failure": None}
    for rec in records:
        msg = rec["msg"]
        banner = BANNER_RE.match(msg)
        if banner:
            parsed["banners"].append({"stage": banner.group(1).strip(), "rec": rec})
            continue
        prog = PROGRESS_RE.search(msg)
        if prog:
            parsed["progress"] = {"stage_index": int(prog.group(1)), "stage": prog.group(2).strip(),
                                  "done": int(prog.group(3)), "total": int(prog.group(4)),
                                  "elapsed": prog.group(5)}
            continue
        for key in HEADER_EQ:
            if msg.startswith(key + " = "):
                parsed["header"][key] = msg[len(key) + 3:].strip()
        for key in HEADER_COLON:
            if msg.startswith(key + ": "):
                parsed["header"][key] = msg[len(key) + 2:].strip()
        tag = TAG_RE.search(msg)
        if tag:
            parsed["header"].setdefault("tag", tag.group(1))
        sha = SHA_RE.search(msg)
        if sha:
            parsed["artifact"] = {"path": sha.group(1),
                                   "sha256": re.sub(r"\s+", "", sha.group(2))}
        step = STEP_RE.search(msg)
        if step:
            parsed["steps"].append({"step_id": step.group(1), "dir": step.group(2), "rec": rec})
        skip = SKIP_RE.search(msg)
        if skip:
            parsed["skips"].append({"name": skip.group(1), "rec": rec})
        if rec["level"] in ("INFO", "WARNING", "ERROR"):
            counted = COUNT_RE.match(msg)
            if counted:
                parsed["verdicts"].append({
                    "level": rec["level"], "gate": gate_for(counted.group("what")),
                    "what": counted.group("what"), "count": int(counted.group("count")),
                    "deferred": bool(counted.group("deferred")), "clock": rec["clock_text"],
                    "rec": rec, "text": msg})
                continue
            cleared = CLEAR_RE.match(msg)
            if cleared:
                parsed["verdicts"].append({
                    "level": rec["level"], "gate": gate_for(cleared.group("what")),
                    "what": cleared.group("what"), "count": 0, "deferred": False,
                    "clock": rec["clock_text"], "rec": rec, "text": msg})
                continue
        if parsed["failure"] is None and rec["level"] == "ERROR":
            deferred = DEFERRED_RE.search(msg)
            if deferred:
                items = [{"count": int(count), "what": what.strip(), "gate": gate_for(what)}
                         for count, what in DEFERRED_ITEM_RE.findall(deferred.group("list"))]
                parsed["failure"] = {"mode": "deferred", "stage": None, "rc": None, "items": items,
                                     "clock": rec["clock_text"], "message": msg}
                continue
            inline = INLINE_RE.search(msg)
            if inline:
                parsed["failure"] = {"mode": "hard", "stage": inline.group("stage").strip(),
                                     "rc": int(inline.group("rc")), "items": [],
                                     "clock": rec["clock_text"], "message": msg}
    return parsed


def build_stages(parsed):
    """Group steps and verdicts under the stage banners, plus synthesised skipped stages."""
    stages = [{"name": b["stage"], "rec": b["rec"], "steps": [], "verdicts": [], "skipped": False}
              for b in parsed["banners"]]
    for step in parsed["steps"]:
        owner = None
        for stage in stages:
            if stage["rec"]["line_no"] <= step["rec"]["line_no"]:
                owner = stage
        if owner is not None:
            owner["steps"].append(step)
    for skip in parsed["skips"]:
        stages.append({"name": skip["name"], "rec": skip["rec"], "steps": [], "verdicts": [],
                       "skipped": True})
    for verdict in parsed["verdicts"]:
        owner = None
        for stage in stages:
            if stage["rec"]["line_no"] <= verdict["rec"]["line_no"]:
                owner = stage
        if owner is not None:
            owner["verdicts"].append(verdict)
    return sorted(stages, key=lambda s: s["rec"]["line_no"])


def finalise_stages(stages, failure, meta, advisory=None):
    # advisory: gate -> items a per-rule tally attributed to an advisory family (see
    # ADVISORY_RULE_SUFFIXES). Empty without --run-dir, which leaves every count blocking.
    advisory = advisory or {}

    def fails(verdict):
        gate = verdict["gate"]
        return verdict_fails(verdict, advisory.get(gate, 0) if gate else 0)

    def item_blocks(item):
        return bool(item["gate"]) and (item["count"] - advisory.get(item["gate"], 0)) > 0

    aborted_at = failure["stage"] if (failure and failure["mode"] == "hard") else None
    failed_gates = set()
    for stage in stages:
        for verdict in stage["verdicts"]:
            if fails(verdict) and verdict["gate"]:
                failed_gates.add(verdict["gate"])
    if failure and failure["mode"] == "deferred":
        for item in failure["items"]:
            if item_blocks(item):
                failed_gates.add(item["gate"])
    blocking_failed = sorted(key for key in failed_gates if BLOCKING.get(key, True))
    completed = bool(stages) and stages[-1]["name"] == "Write the Layout" and aborted_at is None

    out = []
    for index, stage in enumerate(stages, 1):
        step_recs = [s["rec"] for s in stage["steps"]]
        started = step_recs[0]["clock_text"] if step_recs else None
        started_elapsed = step_recs[0]["elapsed"] if step_recs else None
        verdicts = [{"level": v["level"], "gate": v["gate"], "text": v["what"],
                     "count": v["count"], "deferred": v["deferred"], "clock": v["clock"]}
                    for v in stage["verdicts"]]
        failing = [v for v in stage["verdicts"] if fails(v)]
        warning = [v for v in stage["verdicts"] if not fails(v) and
                   (v["count"] or v["level"] == "WARNING")]
        if stage["skipped"]:
            status = "skipped"
        elif aborted_at and stage["name"] == aborted_at:
            status = "fail"
        elif failing:
            status = "fail"
        elif aborted_at:
            status = "not_run"
        elif warning:
            status = "warn"
        elif not completed and index == len(stages):
            status = "incomplete"
        else:
            # a hard failure in this stage would have aborted the flow before the next banner, so
            # a completed stage with no error of its own passed
            status = "pass"
        out.append({
            "index": index,
            "name": stage["name"],
            "status": status,
            "skipped": stage["skipped"],
            "started": started,
            "elapsed_start_s": started_elapsed,
            "steps": [s["step_id"] for s in stage["steps"]],
            "step_dirs": [s["dir"] for s in stage["steps"]],
            "verdicts": verdicts,
            "failure": ({"mode": failure["mode"], "rc": failure["rc"]}
                        if aborted_at and stage["name"] == aborted_at else None),
        })

    # a stage lasts from its own first step to the next stage's first step
    for i, stage in enumerate(out):
        start = stage["elapsed_start_s"]
        nxt = next((s["elapsed_start_s"] for s in out[i + 1:]
                    if s["elapsed_start_s"] is not None), None)
        stage["duration_s"] = None if (start is None or nxt is None) else nxt - start

    gates = []
    for key, label, blocking, _kw in GATES:
        lines = [v for stage in out for v in stage["verdicts"] if v["gate"] == key]
        if not lines:
            gates.append({"gate": key, "label": label, "blocking": blocking, "status": "unknown",
                          "count": None, "clock": None, "stage": None, "evidence": None})
            continue
        worst = max(lines, key=lambda v: (verdict_fails(v, advisory.get(key, 0)), v["count"] or 0))
        # only subtract what the tally accounts for: a truncated report (the top-15 slice, or a
        # file recovered by hand) leaves the rest blocking, because the rest is unattributed
        adv = min(advisory.get(key, 0), worst["count"] or 0)
        blocking_count = None if worst["count"] is None else max(worst["count"] - adv, 0)
        if verdict_fails(worst, adv):
            status = "fail"
        elif worst["count"] or worst["level"] == "WARNING":
            status = "warn"
        else:
            status = "pass"
        owner = next((s["name"] for s in out if any(v is worst for v in s["verdicts"])), None)
        gates.append({"gate": key, "label": label, "blocking": blocking, "status": status,
                      "count": worst["count"], "advisory_count": adv or None,
                      "blocking_count": blocking_count, "deferred": worst["deferred"],
                      "clock": worst["clock"], "stage": owner,
                      "evidence": "%s %s" % (worst["level"], worst["text"])})

    # A deferred failure whose every item is advisory is the flow having reported a warning, not a
    # gate having failed -- but the raw failure block is still kept in the JSON, so the flow's own
    # exception is never hidden by the reclassification.
    deferred_blocking = bool(failure and failure["mode"] == "deferred" and
                             any(item_blocks(item) for item in failure["items"]))
    if aborted_at or not completed:
        result = "incomplete"
    elif blocking_failed:
        result = "fail"
    elif failure and (failure["mode"] == "hard" or deferred_blocking):
        result = "incomplete"
    else:
        result = "pass"
    summary = {
        "result": result,
        "completed": completed,
        "blocking_failed": blocking_failed,
        "non_blocking": ["%s: %s errors (not a gate)" % (g["gate"], g["count"])
                         for g in gates if g["count"] and not g["blocking"]],
        "warnings": ["%s: %s of %s violations are the advisory %s family -- a critical warning, "
                     "not a hard blocker" % (g["gate"], g["advisory_count"], g["count"],
                                             ", ".join(ADVISORY_RULE_SUFFIXES).strip("_"))
                     for g in gates if g.get("advisory_count")],
        "advisory_rules": list(ADVISORY_RULE_SUFFIXES),
    }
    return out, gates, summary


def load_run_dir(run_dir):
    """Pull the run's own numbers: flow.log order, step metrics, per-check report tallies."""
    info = {"flow_steps": [], "flow_skips": [], "metrics": {}, "rules": {}, "reports": []}
    flow_log = os.path.join(run_dir, "flow.log")
    if not os.path.isfile(flow_log):
        found = glob.glob(os.path.join(run_dir, "**", "flow.log"), recursive=True)
        flow_log = found[0] if found else None
    if flow_log:
        info["flow_log"] = flow_log
        with open(flow_log, "r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                step = STEP_RE.search(line)
                if step:
                    info["flow_steps"].append(step.group(1))
                skip = SKIP_RE.search(line)
                if skip:
                    info["flow_skips"].append(skip.group(1))

    for path in sorted(glob.glob(os.path.join(run_dir, "**", "state_*.json"), recursive=True)):
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as handle:
                doc = json.load(handle)
        except (ValueError, OSError):
            continue
        if isinstance(doc, dict) and isinstance(doc.get("metrics"), dict):
            info["metrics"].update(doc["metrics"])

    # `**/reports/*.json` is where the flow writes them; `**/*.klayout.json` also catches a
    # report recovered by hand from a run whose reports/ was not copied out. Files under a
    # reports/ directory win, so a recovered copy never displaces the flow's own output.
    candidates = set()
    for pattern in (os.path.join("**", "reports", "*.json"), os.path.join("**", "*.klayout.json")):
        candidates.update(glob.glob(os.path.join(run_dir, pattern), recursive=True))
    order = sorted(candidates, key=lambda p: (0 if os.sep + "reports" + os.sep in p else 1, p))
    for path in order:
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as handle:
                doc = json.load(handle)
        except (ValueError, OSError):
            continue
        if not isinstance(doc, dict):
            continue
        lower = path.lower()
        if "antenna" in lower:
            gate = "antenna"
        elif "drc" in lower:
            gate = "klayout_drc"
        elif "zero" in lower:
            gate = "zero_area"
        elif "density" in lower:
            gate = "density"
        else:
            gate = None
        info["reports"].append({"path": os.path.relpath(path, run_dir), "gate": gate,
                                "total": doc.get("total")})
        if gate and gate not in info["rules"]:
            info["rules"][gate] = {k: v for k, v in doc.items() if k != "total"}
    return info


def build_verdict(log_path, run_dir, run_info):
    records, meta = load_records(log_path)
    parsed = parse_log(records, meta)
    # The advisory split needs the per-rule tally, which only exists in --run-dir mode; without it
    # every count stays blocking (the log says how many items, not which rules).
    advisory = {}
    for key, rules in ((run_info or {}).get("rules") or {}).items():
        count, _listed = advisory_tally(rules)
        if count:
            advisory[key] = count
    stages, gates, summary = finalise_stages(build_stages(parsed), parsed["failure"], meta, advisory)

    if not stages:
        return ({"schema": SCHEMA, "result": "unparsed",
                 "source": {"log": log_path, "run_dir": run_dir},
                 "reason": "no stage banners found -- is this a precheck run log?",
                 "summary": {"result": "unparsed", "blocking_failed": [], "non_blocking": []}},
                EXIT_UNPARSED)

    seen = [stage["name"] for stage in stages]
    expected = [name for name in EXPECTED_STAGES
                if name != "Check Pad Mask" or "Check Pad Mask" in seen]

    if run_info:
        for gate in gates:
            rules = run_info["rules"].get(gate["gate"])
            if rules:
                gate["rules"] = dict(sorted(rules.items(), key=lambda kv: -kv[1])[:15])
                gate["rules_count"] = len(rules)
                gate["rules_total"] = sum(rules.values())
                # what the tally accounted for, against the count the log reported: when these
                # disagree the tally was truncated, which is why the split stayed conservative
                gate["rules_attributed"] = min(gate["rules_total"], gate["count"] or 0)

    verdict = {
        "schema": SCHEMA,
        "result": summary["result"],
        "source": {"log": log_path, "run_dir": run_dir,
                   "generated_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())},
        "run": {
            "tag": parsed["header"].get("tag"),
            "pdk": parsed["header"].get("PDK"),
            "pdk_root": parsed["header"].get("PDK_ROOT"),
            "top_cell": parsed["header"].get("top_cell"),
            "die_id": parsed["header"].get("die_id"),
            "cob": parsed["header"].get("cob"),
            "slot": parsed["header"].get("slot"),
            "threads": parsed["header"].get("threads"),
            "workers": parsed["header"].get("workers"),
            "date": meta.get("first_date"),
            "clock_start": fmt_clock(meta.get("clock_start")),
            "clock_end": fmt_clock(meta.get("clock_end")),
            "wall_seconds": meta.get("wall_seconds"),
            "flow_progress": parsed["progress"],
            "wrapped_lines_rejoined": meta.get("wrap_joins"),
        },
        "artifact": parsed["artifact"],
        "stages": stages,
        "skipped_steps": [s["name"] for s in parsed["skips"]],
        "gates": gates,
        "metrics": (run_info or {}).get("metrics") or {},
        "reports": (run_info or {}).get("reports") or [],
        "failure": parsed["failure"],
        "summary": {
            "result": summary["result"],
            "completed": summary["completed"],
            "stages_run": len(stages),
            "stages_expected": len(expected),
            "stages_missing": [name for name in expected if name not in seen],
            "blocking_failed": summary["blocking_failed"],
            "non_blocking": summary["non_blocking"],
            "warnings": summary["warnings"],
            "advisory_rules": summary["advisory_rules"],
            "gates": {g["gate"]: g["status"] for g in gates},
            "metrics": (run_info or {}).get("metrics") or {},
            "flow_steps_seen": (run_info or {}).get("flow_steps") or [],
            "flow_skips_seen": (run_info or {}).get("flow_skips") or [],
        },
    }
    if verdict["result"] == "pass":
        exit_code = EXIT_PASS
    elif verdict["result"] == "fail":
        exit_code = EXIT_GATE_FAILURE
    else:
        exit_code = EXIT_INCOMPLETE
    return verdict, exit_code


def print_human(verdict):
    mark = {"pass": "ok  ", "fail": "FAIL", "warn": "warn", "skipped": "skip",
            "not_run": "--  ", "incomplete": "??  "}
    lines = ["%s: %s" % (verdict["result"].upper(), verdict["source"]["log"])]
    for stage in verdict.get("stages", []):
        detail = ""
        if stage["verdicts"]:
            detail = "  (%s)" % "; ".join(
                "%s %s %s" % (v["level"], v["count"], v["text"]) for v in stage["verdicts"])
        elif stage["steps"]:
            detail = "  [%s]" % ", ".join(stage["steps"])
        lines.append("  %s %2d %s%s" % (mark.get(stage["status"], "??  "), stage["index"],
                                         stage["name"], detail))
    for gate in verdict.get("gates", []):
        if gate["status"] == "unknown":
            continue
        extra = ""
        if gate.get("advisory_count"):
            extra = "  advisory=%s blocking=%s" % (gate["advisory_count"], gate["blocking_count"])
        lines.append("  gate %-12s %-5s blocking=%-5s count=%s%s" %
                     (gate["gate"], gate["status"], gate["blocking"], gate["count"], extra))
    if verdict["summary"]["blocking_failed"]:
        lines.append("  blocking gates failed: %s" % ", ".join(
            verdict["summary"]["blocking_failed"]))
    if verdict["summary"]["stages_missing"]:
        lines.append("  stages never reached: %s" % ", ".join(verdict["summary"]["stages_missing"]))
    for warning in verdict["summary"].get("warnings") or []:
        lines.append("  warning %s" % warning)
    print("\n".join(lines), file=sys.stderr)


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Parse a wafer.space gf180mcu precheck run into a JSON verdict.",
        epilog="exit codes: 0 pass, 1 blocking gate failed, 2 incomplete, 3 no verdict "
               "parseable, 4 usage or IO error")
    parser.add_argument("--log", help="the precheck's log (precheck_ws.log)")
    parser.add_argument("--run-dir", help="the run directory (runs/<tag>): metrics and reports")
    parser.add_argument("--out", help="write the JSON here instead of stdout")
    parser.add_argument("--quiet", action="store_true", help="no human summary on stderr")
    parser.add_argument("--expect", choices=["pass", "fail", "incomplete", "unparsed"],
                        help="assert the parsed result (for tests): exit 0 when it matches")
    args = parser.parse_args(argv)

    # Emit UTF-8 regardless of the platform's default encoding (Windows CI defaults to cp1252).
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass

    log_path = args.log
    if not log_path and args.run_dir:
        found = glob.glob(os.path.join(args.run_dir, "**", "precheck*.log"), recursive=True)
        log_path = found[0] if found else None
    if not log_path:
        print("precheck_verdict: need --log, or --run-dir with a precheck*.log inside",
              file=sys.stderr)
        return EXIT_USAGE
    if not os.path.isfile(log_path):
        print("precheck_verdict: no such log: %s" % log_path, file=sys.stderr)
        return EXIT_USAGE

    run_info = None
    if args.run_dir:
        if not os.path.isdir(args.run_dir):
            print("precheck_verdict: no such run directory: %s" % args.run_dir, file=sys.stderr)
            return EXIT_USAGE
        run_info = load_run_dir(args.run_dir)

    try:
        verdict, exit_code = build_verdict(log_path, args.run_dir, run_info)
    except OSError as exc:
        print("precheck_verdict: %s" % exc, file=sys.stderr)
        return EXIT_USAGE

    text = json.dumps(verdict, indent=2) + "\n"
    if args.out:
        with open(args.out, "w", encoding="utf-8") as handle:
            handle.write(text)
    else:
        sys.stdout.write(text)
    if not args.quiet:
        print_human(verdict)

    if args.expect:
        if verdict["result"] != args.expect:
            print("precheck_verdict: expected %s, parsed %s" % (args.expect, verdict["result"]),
                  file=sys.stderr)
            return EXIT_GATE_FAILURE
        return EXIT_PASS
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
