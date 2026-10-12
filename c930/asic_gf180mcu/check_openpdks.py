#!/usr/bin/env python3
"""Check fossi-foundation/open-pdks and efabless for GF180MCU releases"""
import urllib.request
import json

for repo in ["fossi-foundation/open-pdks", "efabless/open-pdks", "RTimothyEdwards/open_pdks"]:
    url = f"https://api.github.com/repos/{repo}/releases"
    req = urllib.request.Request(url, headers={"Accept": "application/vnd.github.v3+json"})
    try:
        data = json.loads(urllib.request.urlopen(req).read())
        for r in data[:3]:
            tag = r["tag_name"]
            assets = r.get("assets", [])
            gf180 = [a for a in assets if "gf180" in a["name"].lower()]
            all_names = [a["name"] for a in assets]
            print(f"{repo}: {tag} - {len(assets)} assets")
            if gf180:
                for a in gf180:
                    print(f"  GF180: {a['name']} ({a['size']/1024/1024:.1f} MB)")
            else:
                for a in assets[:5]:
                    print(f"  {a['name']} ({a['size']/1024/1024:.1f} MB)")
    except Exception as e:
        print(f"{repo}: Error - {e}")
