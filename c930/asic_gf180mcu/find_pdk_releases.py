#!/usr/bin/env python3
"""Find and download GF180MCU PDK for OpenLane2"""
import urllib.request
import json
import sys

# Check chipfoundry/volare releases for PDK assets
url = "https://api.github.com/repos/chipfoundry/volare/releases"
req = urllib.request.Request(url, headers={"Accept": "application/vnd.github.v3+json"})
data = json.loads(urllib.request.urlopen(req).read())

for r in data[:3]:
    tag = r["tag_name"]
    name = r["name"]
    print(f"Release: {tag} ({name})")
    for a in r.get("assets", []):
        aname = a["name"]
        asize = a["size"] / 1024 / 1024
        print(f"  {aname} ({asize:.1f} MB)")
