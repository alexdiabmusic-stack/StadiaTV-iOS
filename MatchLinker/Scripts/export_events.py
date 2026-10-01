"""Pulls the real games for the next 48 hours from public sports feeds (ESPN scoreboard, MLB stats API, NHL web API).

    python3 export_events.py events.json
"""
import json, urllib.request, datetime as dt, time, sys
UA = {"User-Agent": "Mozilla/5.0"}
def get(u):
    for _ in range(2):
        try: return json.load(urllib.request.urlopen(urllib.request.Request(u, headers=UA), timeout=25))
        except Exception: time.sleep(0.5)
    return None
NOW = dt.datetime.now(dt.timezone.utc).replace(second=0, microsecond=0)
END = NOW + dt.timedelta(hours=48)
days = [(NOW + dt.timedelta(days=i)).strftime("%Y%m%d") for i in range(-1, 3)]
events = {}
def add(league, ev):
    comp = (ev.get("competitions") or [{}])[0]; c = comp.get("competitors", [])
    home = next((t for t in c if t.get("homeAway") == "home"), None); away = next((t for t in c if t.get("homeAway") == "away"), None)
    if not home or not away: return
    def team(x): t = x["team"]; return {"name": t.get("displayName"), "short": t.get("shortDisplayName") or t.get("name"), "abbr": t.get("abbreviation") or "", "nick": t.get("name") or "", "city": t.get("location") or ""}
    bc = sorted({n for b in comp.get("broadcasts", []) for n in b.get("names", [])}) or sorted({(g.get("media") or {}).get("shortName") for g in comp.get("geoBroadcasts", []) if (g.get("media") or {}).get("shortName")})
    d = dt.datetime.strptime(ev["date"][:16], "%Y-%m-%dT%H:%M").replace(tzinfo=dt.timezone.utc)
    if not (NOW - dt.timedelta(hours=3) <= d <= END): return
    events[(league, ev["id"])] = {"league": league, "id": ev["id"], "date": ev["date"][:16] + "Z", "name": ev["name"], "home": team(home), "away": team(away), "broadcasts": bc,
                                  "state": ev.get("status", {}).get("type", {}).get("state")}
us = [("football/nfl", "nfl"), ("basketball/nba", "nba"), ("basketball/wnba", "wnba"), ("baseball/mlb", "mlb"), ("hockey/nhl", "nhl"), ("football/college-football", "college-football"),
      ("basketball/mens-college-basketball", "mens-college-basketball"), ("hockey/mens-college-hockey", "mens-college-hockey")]
for lg, path in us:
    for d in days:
        for pname in ("date", "dates"):
            j = get(f"https://cdn.espn.com/core/{path}/scoreboard?xhr=1&{pname}={d}")
            for ev in ((j or {}).get("content", {}).get("sbData", {}).get("events", [])): add(lg, ev)
soccer = ["uefa.champions", "uefa.europa", "uefa.europa.conf", "eng.1", "eng.2", "eng.3", "eng.4", "eng.fa", "eng.league_cup", "esp.1", "esp.2", "esp.copa_del_rey", "ger.1", "ger.2", "ger.dfb_pokal", "ita.1", "ita.2", "ita.coppa_italia",
          "fra.1", "fra.2", "usa.1", "usa.nwsl", "usa.open", "mex.1", "bra.1", "bra.2", "arg.1", "ned.1", "por.1", "sco.1", "tur.1", "bel.1", "aus.1", "jpn.1", "kor.1", "chn.1", "concacaf.champions",
          "conmebol.libertadores", "conmebol.sudamericana", "chi.1", "col.1", "uru.1", "ecu.1", "per.1", "gre.1", "aut.1", "sui.1", "den.1", "swe.1", "nor.1", "rus.1", "ukr.1", "pol.1", "cze.1", "fifa.friendly", "uefa.euroq", "uefa.nations", "fifa.worldq.uefa", "concacaf.nations.league"]
for code in soccer:
    for d in days:
        for pname in ("date", "dates"):
            j = get(f"https://cdn.espn.com/core/soccer/scoreboard?xhr=1&league={code}&{pname}={d}")
            for ev in ((j or {}).get("content", {}).get("sbData", {}).get("events", [])): add("soccer/" + code, ev)
# MLB + NHL from their own APIs (more complete than ESPN cdn's rolling window)
for d in days:
    dd = f"{d[:4]}-{d[4:6]}-{d[6:]}"
    j = get(f"https://statsapi.mlb.com/api/v1/schedule?sportId=1&date={dd}&hydrate=team")
    for x in (j or {}).get("dates", []):
        for g in x["games"]:
            a, h = g["teams"]["away"]["team"], g["teams"]["home"]["team"]
            t = dt.datetime.strptime(g["gameDate"][:16], "%Y-%m-%dT%H:%M").replace(tzinfo=dt.timezone.utc)
            if NOW - dt.timedelta(hours=3) <= t <= END:
                events[("baseball/mlb", "mlb" + str(g["gamePk"]))] = {"league": "baseball/mlb", "id": "mlb" + str(g["gamePk"]), "date": g["gameDate"][:16] + "Z", "name": f'{a["name"]} at {h["name"]}',
                    "home": {"name": h["name"], "short": h.get("teamName"), "abbr": h.get("abbreviation", ""), "nick": h.get("teamName") or "", "city": h.get("locationName") or ""}, "away": {"name": a["name"], "short": a.get("teamName"), "abbr": a.get("abbreviation", ""), "nick": a.get("teamName") or "", "city": a.get("locationName") or ""}, "broadcasts": [], "state": "pre"}
    j = get(f"https://api-web.nhle.com/v1/schedule/{dd}")
    for wk in (j or {}).get("gameWeek", []):
        for g in wk["games"]:
            a, h = g["awayTeam"], g["homeTeam"]
            an = (a.get("placeName", {}).get("default", "") + " " + a.get("commonName", {}).get("default", "")).strip(); hn = (h.get("placeName", {}).get("default", "") + " " + h.get("commonName", {}).get("default", "")).strip()
            t = dt.datetime.strptime(g["startTimeUTC"][:16], "%Y-%m-%dT%H:%M").replace(tzinfo=dt.timezone.utc)
            if NOW - dt.timedelta(hours=3) <= t <= END:
                events[("hockey/nhl", "nhl" + str(g["id"]))] = {"league": "hockey/nhl", "id": "nhl" + str(g["id"]), "date": g["startTimeUTC"][:16] + "Z", "name": f"{an} at {hn}",
                    "home": {"name": hn, "short": h.get("commonName", {}).get("default"), "abbr": h.get("abbrev", ""), "nick": h.get("commonName", {}).get("default") or "", "city": h.get("placeName", {}).get("default") or ""}, "away": {"name": an, "short": a.get("commonName", {}).get("default"), "abbr": a.get("abbrev", ""), "nick": a.get("commonName", {}).get("default") or "", "city": a.get("placeName", {}).get("default") or ""},
                    "broadcasts": [b.get("network") for b in g.get("tvBroadcasts", [])], "state": "pre"}
# de-duplicate MLB/NHL that ESPN also returned (same teams within 30 min)
def key(e): return (e["league"], e["home"]["name"], e["away"]["name"], e["date"][:13])
uniq = {}
for e in events.values():
    k = key(e)
    if k not in uniq or e["id"].startswith(("mlb", "nhl")): uniq[k] = e
out = sorted(uniq.values(), key=lambda e: e["date"])
json.dump(out, open(sys.argv[1] if len(sys.argv) > 1 else "events.json", "w"), indent=1)
from collections import Counter
print(f"window {NOW:%m-%d %H:%MZ} -> {END:%m-%d %H:%MZ}:", len(out), "real events")
for k, v in sorted(Counter(e["league"] for e in out).items(), key=lambda kv: -kv[1]): print(f"   {v:3d}  {k}")
