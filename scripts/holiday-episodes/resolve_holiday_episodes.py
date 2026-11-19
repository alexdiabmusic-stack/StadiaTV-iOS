#!/usr/bin/env python3
"""
Resolves the curated holiday episode lists (christmas-episodes.json, halloween-episodes.json) against TMDB and writes:

  * composeApp/.../features/explore/HolidayEpisodesData.kt  - the verified catalog the app ships (generated; don't edit)
  * scripts/holiday-episodes/verification-report.md / .json - every entry's outcome, for editorial review

The seed lists are the editorial source of truth. Each entry is "series name, season, episode, title". An entry is
accepted only when TMDB has that episode AND its title matches after normalizing punctuation and spelling. Outcomes:

  matched     number and title agree
  variant     number agrees, title differs only in spelling/punctuation (similarity >= 0.88); accepted, listed
  remapped    the title is found at a different number in the same season or among the specials; accepted as an
              alternate mapping and listed for review
  duplicate   resolves to an episode already accepted (a double-length episode TMDB lists once); dropped
  mismatched  TMDB has the number but a different title, and the title is nowhere else in the season; NOT accepted
  unresolved  the season or the series can't be found; NOT accepted
  unavailable TMDB has the episode but it hasn't aired yet; NOT accepted

To add episodes: edit the JSON lists and run this script again. Series names may carry a hint in parentheses: a country
code ("The Office (US)") or a first-air year ("Frasier (1993)") to tell remakes and namesakes apart.

The TMDB key is read from local.properties (TMDB_API_KEY) and never printed.
"""
import datetime
import difflib
import json
import os
import re
import sys
import time
import unicodedata
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
OUT_KT = os.path.join(ROOT, "composeApp/src/commonMain/kotlin/com/nuvio/app/features/explore/HolidayEpisodesData.kt")
CATALOGS = ["christmas-episodes.json", "halloween-episodes.json"]


def api_key():
    for line in open(os.path.join(ROOT, "local.properties")):
        if line.startswith("TMDB_API_KEY"):
            return line.split("=", 1)[1].strip()
    sys.exit("TMDB_API_KEY missing from local.properties")


KEY = api_key()
_cache = {}


def get(path, **query):
    query["api_key"] = KEY
    url = "https://api.themoviedb.org/3/" + path + "?" + urllib.parse.urlencode(query)
    if url in _cache:
        return _cache[url]
    for attempt in range(4):
        try:
            with urllib.request.urlopen(url, timeout=25) as r:
                data = json.load(r)
                _cache[url] = data
                return data
        except urllib.error.HTTPError as e:
            if e.code == 404:
                _cache[url] = None
                return None
            time.sleep(1 + attempt)
        except Exception:
            time.sleep(1 + attempt)
    return None


def normalize(title):
    t = unicodedata.normalize("NFKD", title).encode("ascii", "ignore").decode().lower()
    t = t.replace("&", " and ").replace("'n'", " and ").replace(" n ", " and ")
    t = re.sub(r"[^a-z0-9 ]+", " ", t)
    return re.sub(r"\s+", " ", t).strip()


PART = re.compile(r"\b(part|pt)\s*(\d+|one|two|i+)\b|\(\d\)|\b\d$")


def loose(title):
    """Normalized title without part markers, for spotting double-length episodes TMDB lists once."""
    return re.sub(r"\s+", " ", PART.sub(" ", normalize(title))).strip()


def canonical(title):
    """Normalized, without bracketed tags ("[Christmas]"), a leading "the" or the word "part"."""
    t = re.sub(r"\[[^\]]*\]", " ", title)
    t = normalize(t)
    t = re.sub(r"^the ", "", t)
    t = re.sub(r"\bpart\b", " ", t)
    return re.sub(r"\s+", " ", t).strip()


def shortened(a, b):
    """One title is the other with a prefix added ("Treehouse of Horror Presents: Not It" / "Not It")."""
    x, y = canonical(a), canonical(b)
    short, long_ = (x, y) if len(x) <= len(y) else (y, x)
    return len(short.split()) >= 2 and long_.endswith(" " + short)


def similar(a, b):
    return difflib.SequenceMatcher(None, normalize(a), normalize(b)).ratio()


def parse_series(name):
    m = re.match(r"^(.*?)\s*\((\w+)\)\s*$", name)
    if not m:
        return name, None, None
    base, hint = m.group(1), m.group(2)
    if hint.isdigit() and len(hint) == 4:
        return base, None, hint
    return base, hint.upper(), None


def resolve_series(name):
    base, country, year = parse_series(name)
    results = (get("search/tv", query=base) or {}).get("results", [])
    exact = [r for r in results if normalize(r.get("name", "")) == normalize(base) or normalize(r.get("original_name", "")) == normalize(base)]
    pool = exact or results[:3]
    if country:
        pool = [r for r in pool if country in (r.get("origin_country") or [])] or pool
    if year:
        pool = [r for r in pool if (r.get("first_air_date") or "").startswith(year)] or pool
    if not pool:
        return None
    best = max(pool, key=lambda r: r.get("vote_count", 0))
    details = get(f"tv/{best['id']}", append_to_response="external_ids") or {}
    return {
        "id": best["id"],
        "name": details.get("name") or best.get("name"),
        "first_air_date": details.get("first_air_date") or best.get("first_air_date"),
        "origin_country": details.get("origin_country") or best.get("origin_country"),
        "imdb_id": (details.get("external_ids") or {}).get("imdb_id"),
        "backdrop": details.get("backdrop_path"),
        "poster": details.get("poster_path"),
        "candidates": len(results),
    }


def season(series_id, number):
    return get(f"tv/{series_id}/season/{number}")


def find_by_title(series_id, season_number, title):
    """The episode with this title in the same season, or among the specials; None when absent."""
    for s in (season_number, 0):
        data = season(series_id, s)
        if not data:
            continue
        for ep in data.get("episodes", []):
            if normalize(ep.get("name", "")) == normalize(title) or similar(ep.get("name", ""), title) >= 0.92:
                return s, ep, data
    return None


def resolve(catalog_file, today):
    seed = json.load(open(os.path.join(HERE, catalog_file)))
    accepted, report = [], []
    seen = {}
    for series_name, entries in seed["entries"].items():
        series = resolve_series(series_name)
        for s, e, title in entries:
            row = {"series": series_name, "season": s, "episode": e, "title": title}
            if not series:
                report.append({**row, "status": "unresolved", "note": "series not found on TMDB"})
                continue
            row["tmdb_series_id"] = series["id"]
            data = season(series["id"], s)
            ep = None
            status, note, s_used = None, None, s
            if data:
                ep = next((x for x in data.get("episodes", []) if x.get("episode_number") == e), None)
            if ep and normalize(ep.get("name", "")) == normalize(title):
                status = "matched"
            elif ep and canonical(ep.get("name", "")) == canonical(title):
                status, note = "variant", f'TMDB title "{ep.get("name")}" (tags, "the" or "part" differ)'
            elif ep and similar(ep.get("name", ""), title) >= 0.88:
                status, note = "variant", f'TMDB title "{ep.get("name")}"'
            else:
                found = find_by_title(series["id"], s, title)
                if found:
                    s_used, ep, data = found
                    status = "remapped"
                    note = f'title found at S{s_used:02d}E{ep.get("episode_number"):02d} on TMDB'
                elif ep and loose(ep.get("name", "")) == loose(title):
                    status, note = "variant", f'TMDB title "{ep.get("name")}" (part numbering differs)'
                elif ep and shortened(ep.get("name", ""), title):
                    status, note = "variant", f'TMDB title "{ep.get("name")}" (one title adds a prefix; please confirm)'
                elif ep:
                    status, note = "mismatched", f'TMDB S{s:02d}E{e:02d} is "{ep.get("name")}"'
                elif data:
                    status, note = "unresolved", f"TMDB season {s} has no episode {e}"
                else:
                    status, note = "unresolved", f"TMDB has no season {s}"
            if status in ("matched", "variant", "remapped"):
                air = ep.get("air_date") or ""
                if not air or air > today:
                    status, note = "unavailable", f"not aired yet (air date {air or 'unknown'})"
            if status in ("matched", "variant", "remapped"):
                key = (series["id"], ep["id"])
                if key in seen:
                    status, note = "duplicate", f"same TMDB episode as {seen[key]} (listed once on TMDB)"
                else:
                    seen[key] = f'S{s:02d}E{e:02d} "{title}"'
                    accepted.append({
                        "series_name": series["name"],
                        "series_id": series["id"],
                        "imdb_id": series["imdb_id"],
                        "season": s_used,
                        "episode": ep["episode_number"],
                        "episode_id": ep["id"],
                        "title": ep.get("name") or title,
                        "air_date": ep.get("air_date") or "",
                        "still": ep.get("still_path"),
                        "season_poster": (data or {}).get("poster_path"),
                        "series_backdrop": series["backdrop"],
                        "series_poster": series["poster"],
                        "runtime": ep.get("runtime"),
                        "overview": (ep.get("overview") or "")[:400],
                    })
            report.append({**row, "status": status, "note": note, "tmdb_title": ep.get("name") if ep else None,
                           "resolved_as": f'S{s_used:02d}E{ep["episode_number"]:02d}' if ep and status in ("matched", "variant", "remapped", "duplicate") else None})
        if series:
            report.append({"series": series_name, "series_resolution": True, "tmdb_series_id": series["id"], "tmdb_name": series["name"],
                           "first_air_date": series["first_air_date"], "origin_country": series["origin_country"], "imdb_id": series["imdb_id"]})
    return seed, accepted, report


def kt(s):
    return "null" if s is None else json.dumps(s, ensure_ascii=False).replace("$", "\\$")


def main():
    today = datetime.date.today().isoformat()
    collections = []
    full_report = {}
    for f in CATALOGS:
        seed, accepted, report = resolve(f, today)
        collections.append((seed["collection"], seed["title"], accepted))
        full_report[seed["collection"]] = report

    lines = [
        "// GENERATED by scripts/holiday-episodes/resolve_holiday_episodes.py from the curated JSON lists. Do not edit:",
        "// change the JSON and run the script again. Only entries verified against TMDB (number and title) are here.",
        f"// Resolved {today}.",
        "package com.nuvio.app.features.explore",
        "",
        "internal val HOLIDAY_EPISODE_COLLECTIONS: Map<String, List<HolidayEpisode>> = mapOf(",
    ]
    for cid, _, accepted in collections:
        lines.append(f"    {kt(cid)} to listOf(")
        for a in accepted:
            lines.append(
                "        HolidayEpisode("
                f"seriesTmdbId = {a['series_id']}, seriesImdbId = {kt(a['imdb_id'])}, seriesName = {kt(a['series_name'])}, "
                f"season = {a['season']}, episode = {a['episode']}, episodeTmdbId = {a['episode_id']}, title = {kt(a['title'])}, "
                f"airDate = {kt(a['air_date'])}, still = {kt(a['still'])}, seasonPoster = {kt(a['season_poster'])}, "
                f"seriesBackdrop = {kt(a['series_backdrop'])}, seriesPoster = {kt(a['series_poster'])}, runtime = {a['runtime'] or 'null'}, "
                f"overview = {kt(a['overview'])}),"
            )
        lines.append("    ),")
    lines.append(")")
    open(OUT_KT, "w").write("\n".join(lines) + "\n")

    json.dump(full_report, open(os.path.join(HERE, "verification-report.json"), "w"), indent=1, ensure_ascii=False)
    md = [f"# Holiday episode verification report", "", f"Resolved against TMDB on {today}. Generated by `resolve_holiday_episodes.py`.", ""]
    for cid, title, accepted in collections:
        rows = [r for r in full_report[cid] if not r.get("series_resolution")]
        series_rows = [r for r in full_report[cid] if r.get("series_resolution")]
        counts = {}
        for r in rows:
            counts[r["status"]] = counts.get(r["status"], 0) + 1
        md += [f"## {title}", "", f"{len(rows)} entries, {len(accepted)} accepted. " + ", ".join(f"{k}: {v}" for k, v in sorted(counts.items())), ""]
        md += ["### Series resolution", "", "| Seed name | TMDB id | TMDB name | First aired | Country | IMDb |", "|---|---|---|---|---|---|"]
        md += [f"| {r['series']} | {r['tmdb_series_id']} | {r['tmdb_name']} | {r['first_air_date']} | {','.join(r['origin_country'] or [])} | {r['imdb_id']} |" for r in series_rows]
        md += ["", "### Needs review (everything not a plain match)", "", "| Series | Seed | Status | Note |", "|---|---|---|---|"]
        md += [f"| {r['series']} | S{r['season']:02d}E{r['episode']:02d} {r['title']} | {r['status']} | {r.get('note') or ''} |" for r in rows if r["status"] != "matched"]
        md.append("")
    open(os.path.join(HERE, "verification-report.md"), "w").write("\n".join(md))
    for cid, title, accepted in collections:
        rows = [r for r in full_report[cid] if not r.get("series_resolution")]
        print(title, len(rows), "entries,", len(accepted), "accepted")


if __name__ == "__main__":
    main()
