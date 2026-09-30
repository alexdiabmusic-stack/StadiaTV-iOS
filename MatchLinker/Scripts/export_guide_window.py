"""Cuts a window out of an XMLTV file and writes it as rows the linker CLI reads.

    python3 export_guide_window.py xmltv.xml guide_window.json [hours_back=6] [hours_ahead=54]

Each row: [guide_id, start_unix, end_unix, title, description (first 600 characters)].
"""
import json, re, sys, datetime as dt
import xml.etree.ElementTree as ET

src, dst = sys.argv[1], sys.argv[2]
back = float(sys.argv[3]) if len(sys.argv) > 3 else 6
ahead = float(sys.argv[4]) if len(sys.argv) > 4 else 54
now = dt.datetime.now(dt.timezone.utc)
lo, hi = now - dt.timedelta(hours=back), now + dt.timedelta(hours=ahead)

def parse(s):
    m = re.match(r"^(\d{14})\s*([+-])(\d{2})(\d{2})$", s or "")
    if not m: return None
    t = dt.datetime.strptime(m.group(1), "%Y%m%d%H%M%S")
    off = dt.timedelta(hours=int(m.group(3)), minutes=int(m.group(4)))
    return (t - off if m.group(2) == "+" else t + off).replace(tzinfo=dt.timezone.utc)

rows = []
for _, el in ET.iterparse(src, events=("end",)):
    if el.tag == "programme":
        st, sp = parse(el.get("start")), parse(el.get("stop"))
        if st and sp and sp > lo and st < hi:
            rows.append([el.get("channel"), int(st.timestamp()), int(sp.timestamp()), (el.findtext("title") or "").strip(), (el.findtext("desc") or "").strip()[:600]])
        el.clear()
    elif el.tag == "channel":
        el.clear()
json.dump(rows, open(dst, "w"))
print(f"{len(rows)} programmes in the window, {len({r[0] for r in rows})} channels")
