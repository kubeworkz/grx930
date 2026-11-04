# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""LibreLane plugin: stop Yosys.Synthesis after dfflibmap and write the netlist.

`make mapped` sets SKY130_SYNTH_STOP_AFTER_DFFLIBMAP=1 and runs the Classic
flow with `-T Yosys.Synthesis`.  run_librelane.sh puts this directory on
PYTHONPATH, so LibreLane discovers this module (its name starts with
`librelane_plugin_`) and imports it before the flow starts.

The plugin swaps the synthesis step's script for a copy of LibreLane's own
synthesize.py with one block inserted immediately before the ABC strategy
pass: that block writes the netlist and the stat reports, then exits.  The
insertion point is after dfflibmap and the post-dff stat, so the netlist has
its flops mapped to sky130 cells and its combinational network as ABC's first
(the strategy-free) pass left it.

Why: on this SoC the strategy scripts (AREA_0's `&dch`/`&nf`, AREA_3's legacy
`dch`) do not converge - one run spent 1 h 41 m in `&dch` without a netlist,
another pinned 23.5 GiB in `dch` - while everything before them completes in
about 20 minutes.  The checkpoint makes that completed state visible instead
of losing it.

The netlist is NOT a P&R-ready standard-cell netlist: the combinational cells
are Yosys `$_` gates, so the flow must be stopped at Yosys.Synthesis (the
launcher enforces this) and the result is for inspection/counting only.
"""

import os

from librelane.steps.pyosys import Synthesis

# The line in LibreLane's synthesize.py where the ABC strategy pass is about
# to start.  Everything the snippet needs - `d`, `config`, `lib_arguments`,
# `report_dir`, `output` - is in scope at this point.  Matched without leading
# whitespace so a re-indented engine still stops at the right place.
MARKER = "script_creator = ABCScriptCreator(config)"

SNIPPET = '''
    # -- sky130 mapped-netlist checkpoint (librelane_plugin_sky130_mapped) ---
    # dfflibmap has just run: flops are sky130 cells, combinational logic is
    # ABC's first-pass genlib mapping.  The ABC strategy pass that follows is
    # the one that does not converge on this SoC, so write the checkpoint here
    # instead of losing it.
    if os.environ.get("SKY130_SYNTH_STOP_AFTER_DFFLIBMAP") == "1":
        noattr_flag = ["-noattr"] if config["SYNTH_WRITE_NOATTR"] else []
        # `stat.json` is what Yosys.Synthesis reads after the script returns.
        d.tee("stat", "-json", *lib_arguments, o=os.path.join(report_dir, "stat.json"))
        d.tee("stat", *lib_arguments, o=os.path.join(report_dir, "stat.rpt"))
        # Same flags the strategy pass uses: -noexpr keeps the combinational
        # gate cells as instances instead of folding them back into assigns,
        # which is the point of the checkpoint.
        d.run_pass(
            "write_verilog",
            *noattr_flag,
            "-noexpr",
            "-nohex",
            "-nodec",
            "-defparam",
            output,
        )
        exit(0)
'''

_original_get_script_path = Synthesis.get_script_path


def _write_patched_script(base: str, destination: str) -> None:
    with open(base) as f:
        source = f.read()
    index = source.find(MARKER)
    if index < 0:
        raise RuntimeError(
            f"{base} has no ABC strategy marker; the stop-after-dfflibmap hook "
            "cannot tell where to stop"
        )
    line_start = source.rfind("\n", 0, index) + 1
    with open(destination, "w") as f:
        f.write(source[:line_start] + SNIPPET + source[line_start:])


def get_script_path(self) -> str:
    base = _original_get_script_path(self)
    if os.environ.get("SKY130_SYNTH_STOP_AFTER_DFFLIBMAP") != "1":
        return base
    destination = os.path.join(self.step_dir, "synthesize_stop_after_dfflibmap.py")
    _write_patched_script(base, destination)
    return destination


Synthesis.get_script_path = get_script_path
