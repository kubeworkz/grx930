#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""Download GF180MCU PDK from volare releases and set up for OpenLane2"""
import urllib.request
import json
import os
import subprocess
import sys

# Find the GF180MCU PDK release assets
url = "https://api.github.com/repos/chipfoundry/volare/releases"
req = urllib.request.Request(url, headers={"Accept": "application/vnd.github.v3+json"})
data = json.loads(urllib.request.urlopen(req).read())

gf180_assets = []
for r in data[:10]:
    for a in r.get("assets", []):
        if "gf180mcu" in a["name"].lower():
            gf180_assets.append((r["tag_name"], a["name"], a["browser_download_url"], a["size"]))

if not gf180_assets:
    print("No GF180MCU assets found in releases")
    sys.exit(1)

# Sort by size to find the biggest (most complete) package
gf180_assets.sort(key=lambda x: x[3], reverse=True)

for tag, name, url, size in gf180_assets[:10]:
    print(f"{tag}: {name} ({size/(1024*1024):.1f} MB)")
