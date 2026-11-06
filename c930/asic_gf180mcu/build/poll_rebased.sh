#!/usr/bin/env bash
# Local progress poller for the corrected-netlist re-baseline running on the build server.
while true; do
    timeout 25 ssh -o BatchMode=yes -o StrictHostKeyChecking=no ubuntu@2.31.100.64 '
        cd ~/rebased
        pnr=$(grep -E "Completing|Number of violations|STAGE|PHYSICAL" build/pnr.log 2>/dev/null | tail -1 | sed "s/^[[:space:]]*//")
        run=$(grep -E "^=== |\[\[PNR|\[\[PIPELINE|REFUSED|refused|wrote |placed |pairs|verdict" rebased_run.log 2>/dev/null | tail -2 | tr "\n" " | ")
        printf "%s  PNR: %s\n        RUN: %s\n" "$(date -u +%H:%M:%S)" "${pnr:-none}" "${run:-waiting}"
    ' 2>/dev/null
    sleep 60
done
