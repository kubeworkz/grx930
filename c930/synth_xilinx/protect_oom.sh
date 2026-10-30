#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# protect_oom.sh -- set oom_score_adj=-1000 on all vivado processes (must run as root)
for pid in $(pgrep vivado 2>/dev/null); do
    echo -1000 > /proc/$pid/oom_score_adj 2>/dev/null
done
