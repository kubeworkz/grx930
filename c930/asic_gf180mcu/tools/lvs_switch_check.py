#!/usr/bin/env python3
"""Check that every switch line of the LVS manifest is the one the PDK's config asks for.

Why this exists: build/lvs_fixtures.tsv claims its switch column is not ours. Each line is
supposed to be the per-fixture entry of the pin's `testing/unit/<category>/config/default.yaml`
(`test_switches:`), written out as `key=value`, and a fixture with no entry there is supposed to
carry no switches at all. That claim is the whole reason a green family can be read as "the deck
extracts this device" rather than "the deck extracts it when told to". Until this file existed the
claim was checked by reading the config by eye, and the refresh would happily re-run a manifest
whose switch set somebody had edited -- 51 fixtures, half an hour of docker, a green verdict about
a switch nobody authorized.

So the comparison happens before the first fixture runs, in the refresh, and as its own CI step.
A disagreement is a finding about the manifest (or about a pin whose config moved), and it must be
loud rather than absorbed into a fresh aggregate.

    0  PASS        every manifest line carries exactly what the config says for that fixture
    1  MISMATCH    at least one line disagrees: a switch the manifest asks for and the config does
                   not, one the config asks for and the manifest drops, or a different value for
                   the same switch. Each disagreement is named on its own line.
    2  CANNOT-RUN  the manifest or a config could not be read or understood -- a missing config, a
                   file in a YAML dialect this reader does not implement, a malformed manifest
                   line. Nothing here is evidence either way, and in particular a config this
                   reader cannot parse is NOT reported as agreement.

Usage:
    lvs_switch_check.py --pin <dir> [--manifest <tsv>]

`--pin` is the directory `lvs_fetch_pdk_subset.sh` fills (`build/.lvs_pin`), i.e. the one holding
`testing/unit/`; `--manifest` defaults to `build/lvs_fixtures.tsv` beside it.

The YAML is read by hand, on purpose: the PDK file is a two-level `test_switches:` map of scalars,
and the alternative is a PyYAML dependency on a runner whose python is not ours. The reader
accepts exactly that shape -- `test_switches:` at column 0, a fixture at 2 spaces, a switch at 4 --
plus whole-line comments, and it refuses (exit 2) anything else rather than guessing: a flow
mapping, a tab, a third level, another top-level key. A future upstream config that grows any of
those must fail loudly here, not pass by being ignored.
"""

import argparse
import os
import sys

PREFIX = "LVS-SWITCHES"
BOOLEANS = {"true": "true", "false": "false", "True": "true", "False": "false"}
FLOW = set("{[(|>&*")


def cannot_run(reason):
    print(f"{PREFIX}: CANNOT-RUN {reason}")
    return 2


def mismatch(lines, summary):
    for line in lines:
        print(f"{PREFIX}: MISMATCH {line}")
    print(f"{PREFIX}: MISMATCH {summary}")
    return 1


def read_manifest(path):
    """[(category/fixture, {key: value}), ...] -- comments and blank lines skipped."""
    entries = []
    seen = set()
    with open(path, encoding="utf-8") as fh:
        for lineno, raw in enumerate(fh.read().splitlines(), 1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            name = parts[0].strip()
            if "/" not in name:
                raise ValueError(f"{path}:{lineno}: not <category>/<fixture>: {line!r}")
            if name in seen:
                raise ValueError(f"{path}:{lineno}: {name} appears twice")
            seen.add(name)
            switches = {}
            field = parts[1].strip() if len(parts) > 1 else ""
            for token in field.split(","):
                token = token.strip()
                if not token:
                    continue
                if "=" not in token:
                    raise ValueError(f"{path}:{lineno}: switch {token!r} is not key=value")
                key, value = token.split("=", 1)
                key, value = key.strip(), value.strip()
                if not key or not value:
                    raise ValueError(f"{path}:{lineno}: switch {token!r} is not key=value")
                if key in switches:
                    raise ValueError(f"{path}:{lineno}: {name} sets {key} twice")
                switches[key] = value
            entries.append((name, switches))
    if not entries:
        raise ValueError(f"{path}: no fixtures named")
    return entries


def unquote(value, where, lineno):
    quote = value[0]
    end = value.find(quote, 1)
    if end == -1:
        raise ValueError(f"{where}:{lineno}: unterminated string {value!r}")
    rest = value[end + 1:].strip()
    if rest and not rest.startswith("#"):
        raise ValueError(f"{where}:{lineno}: trailing text after a string: {rest!r}")
    return value[1:end]


def scalar(value, where, lineno):
    """The value as the harness would receive it (`--switch key=value`), for comparison."""
    value = value.strip()
    if not value:
        raise ValueError(f"{where}:{lineno}: a switch with no value")
    if value[0] in FLOW:
        raise ValueError(f"{where}:{lineno}: not a plain scalar: {value!r}")
    if value[0] in "'\"":
        return unquote(value, where, lineno)
    cut = value.find(" #")
    if cut != -1:
        value = value[:cut].strip()
    return BOOLEANS.get(value, value)


def read_config(path, category):
    """{fixture: {key: value}} from a `test_switches:` file, or raise ValueError."""
    fixtures = {}
    current = None
    with open(path, encoding="utf-8") as fh:
        for lineno, raw in enumerate(fh.read().splitlines(), 1):
            if not raw.strip() or raw.strip().startswith("#"):
                continue
            if "\t" in raw[: len(raw) - len(raw.lstrip())]:
                raise ValueError(f"{path}:{lineno}: tab indentation")
            indent = len(raw) - len(raw.lstrip(" "))
            text = raw.strip()
            if indent == 0:
                if text != "test_switches:":
                    raise ValueError(
                        f"{path}:{lineno}: only 'test_switches:' is understood at column 0, "
                        f"found {text!r}"
                    )
                continue
            if indent == 2:
                if not text.endswith(":"):
                    raise ValueError(f"{path}:{lineno}: a fixture line ends with ':'")
                name = text[:-1].strip()
                if not name:
                    raise ValueError(f"{path}:{lineno}: a fixture with no name")
                if name in fixtures:
                    raise ValueError(f"{path}:{lineno}: {name} appears twice in {category}")
                fixtures[name] = {}
                current = name
                continue
            if indent == 4:
                if current is None:
                    raise ValueError(f"{path}:{lineno}: a switch outside any fixture")
                if ":" not in text:
                    raise ValueError(f"{path}:{lineno}: a switch line is not 'key: value'")
                key, value = text.split(":", 1)
                key = key.strip()
                if not key:
                    raise ValueError(f"{path}:{lineno}: a switch with no name")
                if key in fixtures[current]:
                    raise ValueError(f"{path}:{lineno}: {current} sets {key} twice")
                fixtures[current][key] = scalar(value, path, lineno)
                continue
            raise ValueError(f"{path}:{lineno}: unexpected indentation ({indent} spaces)")
    return fixtures


def compare(entries, pin):
    """(differences, fixtures-with-switches, fixtures-on-defaults) for the whole manifest."""
    differences = []
    with_switches = 0
    on_defaults = 0
    for name, wanted in entries:
        category, fixture = name.split("/", 1)
        path = os.path.join(pin, "testing", "unit", category, "config", "default.yaml")
        if not os.path.isfile(path):
            raise FileNotFoundError(path)
        config = read_config(path, category)
        asked = config.get(fixture, {})
        if wanted:
            with_switches += 1
        else:
            on_defaults += 1
        for key in sorted(set(wanted) | set(asked)):
            if key not in asked:
                differences.append(
                    f"{name}: manifest asks {key}={wanted[key]}, the config sets no {key} "
                    f"(the deck would run on its default)"
                )
            elif key not in wanted:
                differences.append(
                    f"{name}: the config sets {key}={asked[key]}, the manifest does not"
                )
            elif wanted[key] != asked[key]:
                differences.append(
                    f"{name}: {key}: manifest asks {wanted[key]!r}, the config says {asked[key]!r}"
                )
    return differences, with_switches, on_defaults


def main(argv=None):
    here = os.path.dirname(os.path.abspath(__file__))
    default_manifest = os.path.join(here, "..", "build", "lvs_fixtures.tsv")
    parser = argparse.ArgumentParser(
        description="Compare the LVS manifest's switches with the pinned PDK's per-fixture config."
    )
    parser.add_argument("--pin", required=True, help="directory holding testing/unit/")
    parser.add_argument("--manifest", default=default_manifest, help="the fixture manifest")
    args = parser.parse_args(argv)

    try:
        entries = read_manifest(args.manifest)
    except (OSError, ValueError) as exc:
        return cannot_run(f"the manifest cannot be read: {exc}")
    try:
        differences, with_switches, on_defaults = compare(entries, args.pin)
    except FileNotFoundError as exc:
        return cannot_run(f"the pin has no {exc} (fetch it, or point --pin at the fetched copy)")
    except (OSError, ValueError) as exc:
        return cannot_run(f"a config cannot be read: {exc}")

    if differences:
        total = len(entries)
        bad = len({line.split(":")[0] for line in differences})
        return mismatch(
            differences,
            f"{bad} of {total} fixtures disagree with the pin's config; "
            f"nothing was run, and the manifest is what has to change",
        )

    print(
        f"{PREFIX}: PASS {len(entries)}/{len(entries)} fixtures carry exactly the switches the "
        f"pin's testing/unit/*/config/default.yaml gives them "
        f"({with_switches} with switches, {on_defaults} on the harness defaults)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
