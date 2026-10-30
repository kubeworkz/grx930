# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# Standalone TritonRoute experiment driver for the preserved pre-DRT database.
# The ODB is self-contained (tech + cells), so no LEF/PDK files are read.
set out "$::env(FAST_OUT)"
file mkdir $out
puts "FAST_DRT_START tag=$::env(FAST_TAG) end_iter=$::env(FAST_END_ITER) layers=$::env(FAST_MIN_LAYER)-$::env(FAST_MAX_LAYER) threads=$::env(FAST_THREADS)"
read_db $::env(FAST_ODB)
set_thread_count $::env(FAST_THREADS)
detailed_route \
    -bottom_routing_layer $::env(FAST_MIN_LAYER) \
    -top_routing_layer $::env(FAST_MAX_LAYER) \
    -output_drc $out/$::env(FAST_TAG).drc \
    -droute_end_iter $::env(FAST_END_ITER) \
    -or_seed 42 \
    -verbose 1
write_db $out/$::env(FAST_TAG).odb
puts "FAST_DRT_DONE"
