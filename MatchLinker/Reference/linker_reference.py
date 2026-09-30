"""Match -> stream linker, prototype v1.

Evidence sources, all taken from the playlist itself:
  * guide:      the playlist's own XMLTV (programme title / description / time, per guide id)
  * names:      event-slot channel names ("US * MLB 01: PHILADELPHIA PHILLIES @ ATLANTA BRAVES 2:00 PM ET")
  * team feeds: channels named after a single team ("US * MLB TEAMS : Boston Red Sox HD")
  * rights:     networks the sports-data API says carry the game (ESPN, TNT, SN ...), used as support only
"""
import re, json, unicodedata, datetime as dt, collections
from zoneinfo import ZoneInfo

# ------------------------------------------------------------------ text utilities
def nfkd(s): return unicodedata.normalize("NFKD", s or "")

def fold(s):
    s = "".join(c for c in nfkd(s) if not unicodedata.combining(c))
    return s.replace("ɪ", "i").replace("ᴀ", "a").lower()        # small-capital I / A left over from superscript badges

def words(s): return re.findall(r"[^\W_]+", fold(s))
def clean(s): return " ".join(words(s))

BADGE_TAIL = re.compile(r"[ʰ-˿ᴬ-ᶿ⁰-₟]+\s*$")
def split_badge(title):
    m = BADGE_TAIL.search(title or "")
    if not m: return (title or "").strip(), ""
    return title[:m.start()].strip(), fold(m.group(0))

def has_phrase(text, phrase):
    """whole-word phrase containment on already-cleaned text"""
    return (" " + phrase + " ") in (" " + text + " ")

CONNECTORS = {"de", "del", "di", "da", "do", "dos", "das", "du", "of", "the", "van", "von", "der", "den", "af"}
def nocon(c): return " ".join(t for t in c.split() if t not in CONNECTORS)      # "atletico de san luis" -> "atletico san luis"
def variants(c):
    k = nocon(c)
    return (c,) if k == c else (c, k)
def has_any(texts, aliases): return any(has_phrase(t, p) for t in texts for p in aliases)

# ------------------------------------------------------------------ team identity
GENERIC = set("fc cf sc afc ac as cd ca club deportivo real sporting athletic atletico united city town county state university st saint los las new de del la el the of and sk fk bk if ik islands island".split())
NICK_STOP = set("city united town state county rovers wanderers athletic albion rangers".split())   # too club-generic to stand alone (Rangers is handled by the pair rule)

COUNTRY = {}      # core-normalised country name (any language) -> region code, filled from country_aliases.json
REGION_NAMES = collections.defaultdict(set)
CORE_STOP = {"and", "the", "of", "de", "la", "el", "republic"}
def core(s):
    c = clean(s).replace("u s ", "us ").replace("st ", "saint ")
    return " ".join(t for t in c.split() if t not in CORE_STOP)
def load_countries(path="country_aliases.json"):
    data = json.load(open(path))
    data.setdefault("PF", []).append("Tahiti")
    for code, names in data.items():
        for n in names:
            c = core(n)
            if c: COUNTRY[c] = code; REGION_NAMES[code].add(clean(n))

def all_generic(a): return all(t in GENERIC for t in a.split())
def team_aliases(team, national, full_only=False):
    full = clean(team["name"]); short = clean(team.get("short") or ""); nick = clean(team.get("nick") or ""); city = clean(team.get("city") or "")
    al = {full}
    if not full_only:
        for x in (short, nick):
            if len(x) >= 4 and not all_generic(x): al.add(x)
        if city and nick and not all_generic(nick): al.add(city + " " + nick)
    if national:
        code = COUNTRY.get(core(team["name"])) or COUNTRY.get(core(team.get("short") or ""))
        if code: al |= REGION_NAMES[code]
        for alt in {"united states": ["usa", "us", "united states of america", "u s"], "czechia": ["czech republic"], "north macedonia": ["macedonia"],
                    "england": ["inglaterra", "angleterre", "inghilterra", "engeland"], "scotland": ["escocia", "ecosse", "schottland", "schotland", "scozia"]}.get(full, []): al.add(alt)
    for a in list(al):
        k = nocon(a)
        if k != a: al.add(k)
    return {a for a in al if len(a) >= 3 and not all_generic(a)}

def weak_abbr(team): return fold(team.get("abbr") or "")

# ------------------------------------------------------------------ programme classification
SEP = re.compile(r"\s(?:vs\.?|v\.?|versus|at|@|c\.|x|contre|gegen|contra|-|–|—)\s", re.I)
PLACEHOLDER = re.compile(r"^\s*(?:no\s+(?:game|match|event)s?(?:\s+today|\s+scheduled)?|next\s+(?:game|match)|teams?\s+tba|to\s+be\s+announced|tbd|off\s+air|programming\s+resumes|sign\s*off|check\s+local)", re.I)
REPLAY = re.compile(r"\b(?:replay|re-?run|re-?air|encore|classics?|highlights?|condensed|recap|recorded|tape[- ]delay(?:ed)?|delayed|throwback|archive|best\s+of|resumen|zusammenfassung|magazine|melhores\s+momentos)\b", re.I)
COVERAGE = re.compile(r"\b(?:in-?game|pre-?game|post-?game|pre-?show|post-?show|preview|countdown|analysis|studio|scoreboard|tonight|whip|betting|odds|picks|fantasy|talk|weekly|report|daily|live\s+look|coverage\s+of)\b", re.I)

def fixture_in(head, a_al, b_al):
    """True if head reads 'A <sep> B' (either order) for the two alias sets; also returns number of separators."""
    h = nfkd(head)
    seps = list(SEP.finditer(h))
    if not seps: return False, 0
    for m in seps:
        left, right = variants(clean(h[:m.start()])), variants(clean(h[m.end():]))
        for x, y in ((a_al, b_al), (b_al, a_al)):
            if has_any(left, x) and has_any(right, y): return True, len(seps)
    return False, len(seps)

def names_both(text, a_al, b_al):
    c = variants(clean(text))
    return has_any(c, a_al) and has_any(c, b_al)

def distinctive_tokens(team, national, exclude=frozenset()):
    out = set()
    for a in team_aliases(team, national):
        for t in a.split():
            if len(t) >= 5 and t not in GENERIC: out.add(t)
    return out - set(exclude)

def fuzzy_fixture(head, ta, tb):
    """name variants ('Celta B' vs 'RC Celta Fortuna'): one separator, each side holds a distinctive token of a different team"""
    h = nfkd(head)
    seps = list(SEP.finditer(h))
    if len(seps) != 1 or len(head) >= 100: return False
    m = seps[0]
    left, right = set(words(h[:m.start()])), set(words(h[m.end():]))
    return (bool(left & ta) and bool(right & tb)) or (bool(left & tb) and bool(right & ta))

# ------------------------------------------------------------------ channel-name events
TZ = {"ET": "America/New_York", "EST": "America/New_York", "EDT": "America/New_York", "CT": "America/Chicago", "CST": "America/Chicago", "CDT": "America/Chicago",
      "MT": "America/Denver", "PT": "America/Los_Angeles", "PST": "America/Los_Angeles", "PDT": "America/Los_Angeles", "UK": "Europe/London", "GMT": "Europe/London",
      "BST": "Europe/London", "CET": "Europe/Paris", "CEST": "Europe/Paris"}
TIME_RE = re.compile(r"\b(\d{1,2})(?::(\d{2}))?\s*(AM|PM)\s*(ET|EST|EDT|CT|CST|CDT|MT|PT|PST|PDT|UK|GMT|BST|CET|CEST)?\b", re.I)
ISO_RE = re.compile(r"\b(20\d{2})-(\d{2})-(\d{2})(?:\s+(\d{2}):(\d{2}))?")
PREFIX_RE = re.compile(r"^\s*(?:[A-Z]{2,4}\s*[★⭐*|:]+\s*)+")
SLOT_RE = re.compile(r"^\s*(?:[A-Z0-9+ ]{2,14}?)\s*\d{1,4}\s*:\s*")

def parse_event_name(name):
    """-> dict(head, times=[(h,m,tz)], iso=(y,mo,d,h,m)|None) or None"""
    n = nfkd(name)
    n = PREFIX_RE.sub("", n)
    n = re.sub(r"\[(?:HD|FHD|UHD|SD|4K|BACKUP|BK)\]", " ", n, flags=re.I)
    times = []
    for m in TIME_RE.finditer(n):
        h = int(m.group(1)) % 12 + (12 if m.group(3).upper() == "PM" else 0)
        times.append((h, int(m.group(2) or 0), (m.group(4) or "ET").upper()))
    iso = ISO_RE.search(n)
    head = n
    return {"head": head, "times": times, "iso": tuple(int(x) if x else None for x in iso.groups()) if iso else None}

def kickoff_matches(times, kickoff_utc, tol_min=25):
    """does any time in the name equal the kickoff, in the zone the name states?"""
    for h, mi, tz in times:
        z = ZoneInfo(TZ.get(tz, "America/New_York"))
        k = kickoff_utc.astimezone(z)
        if abs((k.hour * 60 + k.minute) - (h * 60 + mi)) <= tol_min: return True
    return False

# ------------------------------------------------------------------ playlist model
QUAL = [("4k", 9), ("uhd", 9), ("fhd", 8), ("1080", 8), ("hd", 6), ("720", 5), ("sd", 2)]
def stream_quality(name):
    n = fold(name); q = 4
    for k, v in QUAL:
        if re.search(rf"\b{k}\b", n): q = max(q, v) if q != 4 else v
    if re.search(r"\b(?:backup|bk|bckp)\b", n): q -= 3
    return q

def display_name(name):
    n = PREFIX_RE.sub("", nfkd(name))
    n = re.sub(r"[◉●★]|\b(?:HD|FHD|UHD|SD|4K)\b", " ", n, flags=re.I)
    return re.sub(r"\s+", " ", n).strip(" :-")

def region_of(name, guide_id):
    m = re.match(r"^\s*([A-Z]{2,4})\s*[★⭐*|:]", nfkd(name))
    if m: return m.group(1).upper()
    if guide_id and "." in guide_id: return guide_id.rsplit(".", 1)[1].upper()
    return ""

class Ctx:
    def __init__(self, streams, cats, progs):
        self.streams = streams
        self.cat = {c["category_id"]: c["category_name"] for c in cats}
        self.by_guide = collections.defaultdict(list)
        for s in streams:
            g = (s.get("epg_channel_id") or "").strip().lower()
            if g: self.by_guide[g].append(s)
        self.progs = sorted(progs, key=lambda p: p[1])
        self.parsed = {s["stream_id"]: parse_event_name(s["name"]) for s in streams if re.search(r"(?:\bvs\.?\b|\bv\b|@|\bat\b|\s-\s)", s["name"], re.I)}
        self.starts = [p[1] for p in self.progs]

    def window(self, t0, t1):
        import bisect
        lo = bisect.bisect_left(self.starts, t0 - 8 * 3600)          # a programme can start up to 8h before and still cover the time
        hi = bisect.bisect_right(self.starts, t1)
        return [p for p in self.progs[lo:hi] if p[2] >= t0 and p[1] <= t1]

# ------------------------------------------------------------------ rights: API broadcaster name -> playlist channel matcher
def net_key(name):
    n = clean(display_name(name))
    n = re.sub(r"\b(east|west|pacific|central|mountain|hd|fhd|uhd|sd|4k|feed|live|plus)\b", " ", n)
    return re.sub(r"\s+", "", n)
NETWORKS = {   # API name (folded, no spaces) -> exact playlist network keys
    "espn": ["espn"], "espn2": ["espn2"], "espnu": ["espnu"], "tnt": ["tnt"], "trutv": ["trutv"], "sn": ["sportsnet", "sportsnetontario", "sportsnetone", "sportsneteast", "sportsnetpacific", "sportsnetwest", "sportsnet360"],
    "tvas": ["tvasports"], "tvas2": ["tvasports2"], "cnbc": ["cnbc"], "usanet": ["usanetwork"], "fs1": ["foxsports1", "fs1"], "fs2": ["foxsports2", "fs2"], "universo": ["nbcuniverso", "universo"],
    "msgsn": ["msgsportsnet", "msgsn", "msg"], "abc": ["abc"], "cbs": ["cbs"], "nbc": ["nbc"], "fox": ["fox"], "tsn": ["tsn", "tsn1", "tsn2", "tsn3", "tsn4", "tsn5"], "nflnetwork": ["nflnetwork"], "mlbnetwork": ["mlbnetwork"],
    "nhlnetwork": ["nhlnetwork"], "goltv": ["goltv"], "univision": ["univision"], "telemundo": ["telemundo"], "cbssn": ["cbssportsnetwork"], "peacock": [], "hbomax": [], "primevideo": [], "prime": [], "appletv": [], "paramount": [], "max": [],
}
NET_REGION = {"espn": "US", "espn2": "US", "espnu": "US", "tnt": "US", "trutv": "US", "cnbc": "US", "usanet": "US", "fs1": "US", "fs2": "US", "universo": "US", "msgsn": "US", "abc": "US", "cbs": "US", "nbc": "US", "fox": "US", "nflnetwork": "US", "mlbnetwork": "US", "nhlnetwork": "US", "univision": "US", "telemundo": "US", "cbssn": "US", "goltv": "US",
              "sn": "CA", "tvas": "CA", "tvas2": "CA", "tsn": "CA"}
def rights_streams(ctx, api_names):
    want = {}                                            # network key -> allowed region
    for n in api_names:
        k = re.sub(r"[^a-z0-9]", "", fold(n))
        for nk in NETWORKS.get(k, []): want[nk] = NET_REGION.get(k, "US")
    out = []
    for s in ctx.streams:
        nk = net_key(s["name"])
        if nk in want:
            reg = region_of(s["name"], s.get("epg_channel_id") or "")
            reg = "CA" if reg in ("CAF",) else reg
            if reg == want[nk]: out.append(s)
    return out

# ------------------------------------------------------------------ leagues -> generic words used to recognise a league slot
LEAGUE_WORDS = {"hockey/nhl": ["nhl", "hockey"], "baseball/mlb": ["mlb", "baseball"], "basketball/wnba": ["wnba"], "basketball/nba": ["nba"], "football/nfl": ["nfl"], "soccer/usa.1": ["mls"]}

SPORT_LEN = {"hockey": 3.0, "baseball": 3.5, "basketball": 2.5, "soccer": 2.0, "football": 3.5}
def is_national(event): return any(k in event["league"] for k in ("fifa.", "uefa.nations", "uefa.euro", "concacaf.nations", "worldq"))

LANG = {"US": "en", "CA": "en", "UK": "en", "GB": "en", "AU": "en", "NL": "nl", "DE": "de", "AT": "de", "CH": "de", "FR": "fr", "BE": "fr", "IT": "it", "ES": "es", "AR": "es", "MX": "es", "PT": "pt", "BR": "pt", "PL": "pl", "GR": "el", "TR": "tr", "BI-AR": "ar"}

NEXT_GAME = re.compile(r"next\s+(?:game|match)\s*:?\s*(.+?)\s+on\s+(\d{4})-(\d{2})-(\d{2})", re.I)

def family_of(name, region):
    toks = clean(display_name(name)).split()
    stop = {"hd", "fhd", "uhd", "sd", "east", "west", "pacific", "central", "feed", "channel", "tv"}
    toks = [t for t in toks if t not in stop and not t.isdigit()]
    return (region or "?") + ":" + (toks[0] if toks else "?")

def link(event, ctx, k_pre_min=30, k_post_min=15, horizon_grace_min=10):
    ko = dt.datetime.strptime(event["date"], "%Y-%m-%dT%H:%MZ").replace(tzinfo=dt.timezone.utc)
    kts = int(ko.timestamp()); nat = is_national(event)
    A, B = team_aliases(event["home"], nat), team_aliases(event["away"], nat)
    FA, FB = team_aliases(event["home"], nat, True), team_aliases(event["away"], nat, True)
    shared = A & B; A -= shared; B -= shared
    full_a, full_b = {clean(event["home"]["name"])}, {clean(event["away"]["name"])}
    _da, _db = distinctive_tokens(event["home"], nat), distinctive_tokens(event["away"], nat)
    tokA, tokB = _da - _db, _db - _da
    feeds = collections.OrderedDict()

    def add(key, streams, tier, conf, label, why, prog=None):
        f = feeds.setdefault(key, {"streams": streams, "tier": "T9", "conf": 0.0, "label": "", "why": None, "prog": None})
        if conf > f["conf"]: f.update(tier=tier, conf=conf, label=label, why=why, prog=prog)

    covered = set()     # guide ids that have any programme overlapping the kickoff (used to detect schedule horizons)
    league_w = LEAGUE_WORDS.get(event["league"], [])
    # ---- T1/T2/T6: the playlist's own guide
    for ch, st, en, title, desc in ctx.window(kts + k_post_min * 60, kts + k_pre_min * 60):
        if st > kts + k_pre_min * 60 or en < kts + k_post_min * 60: continue
        gid = (ch or "").lower()
        if en - st <= 6 * 3600: covered.add(gid)
        if en - st > 6 * 3600: 
            m = NEXT_GAME.search(title)
            streams = ctx.by_guide.get(gid)
            if m and streams:                                             # "Next Game: A @ B on 2026-10-01" placeholder on a dedicated team channel
                fx = m.group(1)
                if names_both(fx, A, B) and abs((dt.date(int(m.group(2)), int(m.group(3)), int(m.group(4))) - ko.date()).days) <= 1:
                    add("g:" + gid, streams, "T3", 0.62, "Team channel", f"guide {ch}: {title[:70]}", (title, st, en))
            continue
        streams = ctx.by_guide.get(gid)
        if not streams: continue
        head, badge = split_badge(title)
        if PLACEHOLDER.search(head):
            m = NEXT_GAME.search(head)
            if m and names_both(m.group(1), A, B) and abs((dt.date(int(m.group(2)), int(m.group(3)), int(m.group(4))) - ko.date()).days) <= 1:
                add("g:" + gid, streams, "T3", 0.62, "Team channel", f"guide {ch}: {title[:70]}", (title, st, en))
            continue
        replay = bool(REPLAY.search(head)); coverage = bool(COVERAGE.search(head))
        if replay: continue
        ok, nseps = fixture_in(head, A, B)
        matched = False
        if ok:
            conf = (0.97 if "live" in badge else 0.92) if nseps == 1 else 0.8
            if coverage: add("g:" + gid, streams, "T6", 0.35, "Coverage show", f"guide {ch}: {title[:70]}", (title, st, en))
            else: add("g:" + gid, streams, "T1", conf, "Live listing", f"guide {ch}: {title[:70]}", (title, st, en))
            matched = True
        elif names_both(head, A, B):
            add("g:" + gid, streams, "T1" if not coverage else "T6", 0.7 if not coverage else 0.3, "Live listing" if not coverage else "Coverage show", f"guide {ch}: {title[:70]}", (title, st, en))
            matched = True
        if not matched and not names_both(head, A, set()) and not names_both(head, set(), B) and names_both(desc[:300], FA, FB) and not REPLAY.search(desc[:200]):
            add("g:" + gid, streams, "T2", 0.72, "Live listing (description)", f"guide {ch}: {title[:60]} || {desc[:60]}", (title, st, en))
            matched = True
        if not matched and not coverage and fuzzy_fixture(head, tokA, tokB):
            add("g:" + gid, streams, "T1", 0.75, "Live listing (name variant)", f"guide {ch}: {title[:70]}", (title, st, en))

    # ---- T3: "Next Game: A @ B on <date>" entries that start hours before kickoff on a dedicated team channel
    for ch, st, en, title, desc in ctx.window(kts - 36 * 3600, kts + k_pre_min * 60):
        if "next" not in title.lower(): continue
        gid = (ch or "").lower(); streams = ctx.by_guide.get(gid)
        m = NEXT_GAME.search(title)
        if m and streams and names_both(m.group(1), A, B) and abs((dt.date(int(m.group(2)), int(m.group(3)), int(m.group(4))) - ko.date()).days) <= 1:
            add("g:" + gid, streams, "T3", 0.62, "Team channel", f"guide {ch}: {title[:70]}", (title, st, en))

    # ---- T4: event-slot channels whose NAME carries the fixture
    for s in ctx.streams:
        p = ctx.parsed.get(s["stream_id"])
        if not p: continue
        ok, nseps = fixture_in(p["head"], A, B)
        if not ok: continue
        if p["iso"]:
            y, mo, d = p["iso"][:3]
            if abs((dt.date(y, mo, d) - ko.date()).days) > 1: continue
        if p["times"]:
            if kickoff_matches(p["times"], ko): add("n:%s" % s["stream_id"], [s], "T4", 0.85, "Event channel", f"channel name: {s['name'][:70]}")
        else: add("n:%s" % s["stream_id"], [s], "T4", 0.5, "Event channel (no time)", f"channel name (no time): {s['name'][:70]}")

    # ---- T3: dedicated team channels named after a participant (full team name in the channel name, sports category)
    for s in ctx.streams:
        cat = ctx.cat.get(s["category_id"], "")
        if not re.search(r"\b(teams?|nhl|nba|mlb|nfl|mls|sports?|wnba)\b", fold(cat)): continue
        n = clean(display_name(s["name"]))
        if len(n.split()) > 7: continue
        if has_any(variants(n), full_a | full_b | {nocon(f) for f in full_a | full_b}) and not ctx.parsed.get(s["stream_id"]):
            gid = (s.get("epg_channel_id") or "").lower()
            if ("g:" + gid) in feeds: continue                      # already explained by a real listing
            add("t:%s" % s["stream_id"], [s], "T3", 0.5, "Team channel (unverified)", f"team channel: {s['name'][:60]}")

    # ---- T5: rights holders named by the sports-data API; kept unless the channel's own guide contradicts
    for s in rights_streams(ctx, event["broadcasts"]):
        gid = (s.get("epg_channel_id") or "").lower()
        if ("g:" + gid) in feeds: continue
        if gid and gid in covered:
            continue               # its guide has a programme at kickoff that is not this game -> not carrying it
        why = "sports data lists this network" + (" (channel guide ends before kickoff)" if gid else " (channel has no guide)")
        add("r:" + (gid or str(s["stream_id"])), ctx.by_guide.get(gid) or [s], "T5", 0.6, "Likely (broadcast partner)", why)
    return ko, feeds
