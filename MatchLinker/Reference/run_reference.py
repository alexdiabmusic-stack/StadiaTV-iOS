"""Runs the Python reference linker with the same inputs and output shape as linker-cli, so the two can be compared.

    python3 run_reference.py DIR guide.json events.json out.json

DIR holds streams.json and cats.json. Then:  python3 compare_results.py out_reference.json out_swift.json
"""
import json, sys, collections
import linker_reference as L

d, guide, events, out = sys.argv[1:5]
L.load_countries("country_aliases.json")
streams = json.load(open(f"{d}/streams.json")); cats = json.load(open(f"{d}/cats.json"))
ctx = L.Ctx(streams, cats, json.load(open(guide)))
rows = []
for e in json.load(open(events)):
    _, feeds = L.link(e, ctx)
    opts = []
    for key, f in feeds.items():
        ss = sorted(f["streams"], key=lambda s: -L.stream_quality(s["name"]))
        reg = L.region_of(ss[0]["name"], ss[0].get("epg_channel_id") or "")
        opts.append({"key": key, "tier": f["tier"], "conf": f["conf"], "label": f["label"], "region": reg, "name": L.display_name(ss[0]["name"]), "n": len(ss),
                     "family": L.family_of(ss[0]["name"], reg), "why": f["why"] or "", "prog": f["prog"][0] if f["prog"] else "", "streams": [s["stream_id"] for s in ss]})
    opts.sort(key=lambda o: -o["conf"])
    rows.append({"event": e, "options": opts})
json.dump(rows, open(out, "w"), indent=1)
confident = sum(1 for r in rows if any(o["conf"] >= 0.7 for o in r["options"]))
print(f"{len(rows)} games, {confident} with a confident option")
