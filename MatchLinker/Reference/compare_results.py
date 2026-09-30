"""Strict comparison of two result files (reference vs Swift): feeds, tiers, confidences, family, region, stream lists and option order.

    python3 compare_results.py out_reference.json out_swift.json
"""
import json, sys

a = json.load(open(sys.argv[1])); b = json.load(open(sys.argv[2]))
assert len(a) == len(b), f"different number of games: {len(a)} vs {len(b)}"
bad = 0
for ra, rb in zip(a, b):
    ea = ra["event"]; assert ea["id"] == rb["event"]["id"]
    A = {o["key"]: o for o in ra["options"]}; B = {o["key"]: o for o in rb["options"]}
    problems = []
    if list(A) != list(B): problems.append(f"feeds or order differ: {sorted(set(A) ^ set(B))[:4] or 'order only'}")
    for k in set(A) & set(B):
        x, y = A[k], B[k]
        if (x["tier"], round(x["conf"], 2)) != (y["tier"], round(y["conf"], 2)): problems.append(f"{k}: {x['tier']} {x['conf']} vs {y['tier']} {y['conf']}")
        if [str(s) for s in x["streams"]] != [str(s) for s in y["streams"]]: problems.append(f"{k}: stream lists differ")
        if (x["family"], x["region"]) != (y["family"], y["region"]): problems.append(f"{k}: family or region differ")
    if problems:
        bad += 1
        if bad <= 10: print(f"{ea['date']} {ea['name']}: " + "; ".join(problems[:3]))
print(f"identical games: {len(a) - bad} of {len(a)}")
sys.exit(1 if bad else 0)
