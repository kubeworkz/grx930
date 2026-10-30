# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
read_db /work/openlane2_rtl/runs/RUN_2026-09-24_04-18-20/39-openroad-globalrouting/grx930_test_chip.odb
if { [grt::have_routes] } {
    puts "PROBE_RESULT: HAS_ROUTES"
} else {
    puts "PROBE_RESULT: NO_ROUTES"
}
