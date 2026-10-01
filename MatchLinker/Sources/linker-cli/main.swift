import Foundation
import BannerTV

// CLI harness: reads the same JSON fixtures the Python prototype uses, runs StreamLinker, writes results in the same shape.
// usage: linker_cli <fixtureDir> <guide.json> <events.json> <out.json>

let args = CommandLine.arguments
guard args.count >= 5 else { print("usage: linker_cli <dir> <guide.json> <events.json> <out.json>"); exit(2) }
let dir = args[1]

func load(_ name: String) -> Any {
    let path = name.hasPrefix("/") ? name : dir + "/" + name
    return try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))
}

/// JSONSerialization hands back bridged NSStrings; the app's parser produces native strings, so normalise before timing.
func native(_ s: String) -> String { var t = s; t.makeContiguousUTF8(); return t }

let cats = (load("cats.json") as! [[String: Any]]).reduce(into: [String: String]()) { $0[$1["category_id"] as! String] = $1["category_name"] as? String }
var streams: [LinkerStream] = []
for s in load("streams.json") as! [[String: Any]] {
    let id = String(describing: s["stream_id"]!)
    let cat = cats[(s["category_id"] as? String) ?? ""] ?? ""
    let g = s["epg_channel_id"] as? String
    streams.append(LinkerStream(id: id, name: native((s["name"] as? String) ?? ""), category: native(cat), guideID: (g?.isEmpty ?? true) ? nil : native(g!)))
}
var programmes: [LinkerProgramme] = []
for p in load(args[2]) as! [[Any]] {
    programmes.append(LinkerProgramme(guideID: native(p[0] as! String), start: Date(timeIntervalSince1970: (p[1] as! NSNumber).doubleValue), end: Date(timeIntervalSince1970: (p[2] as! NSNumber).doubleValue),
                                      title: native(p[3] as! String), desc: (p[4] as? String).map(native)))
}
let repeatCount = Int(ProcessInfo.processInfo.environment["LINKER_REPEAT"] ?? "1") ?? 1       // rebuild/relink N times and report the best build and pooled link times
func wallMs() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e6 }
func cpuMs() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e6 }      // this thread's CPU time: unaffected by other processes competing for cores
var linker = StreamLinker(streams: [], programmes: [])
var buildWall: [Double] = [], buildCPU: [Double] = []
for _ in 0..<repeatCount {
    let w0 = wallMs(), c0 = cpuMs()
    linker = StreamLinker(streams: streams, programmes: programmes)
    buildWall.append(wallMs() - w0); buildCPU.append(cpuMs() - c0)
}

let fmt = DateFormatter(); fmt.locale = Locale(identifier: "en_US_POSIX"); fmt.timeZone = TimeZone(identifier: "UTC"); fmt.dateFormat = "yyyy-MM-dd'T'HH:mm'Z'"
func team(_ d: [String: Any]) -> LinkerTeam {
    LinkerTeam(name: d["name"] as? String ?? "", short: d["short"] as? String, nick: d["nick"] as? String, city: d["city"] as? String, abbr: d["abbr"] as? String)
}
let nationalKeys = ["fifa.", "uefa.nations", "uefa.euro", "concacaf.nations", "worldq"]
var results: [[String: Any]] = []
var linkWall: [Double] = [], linkCPU: [Double] = []
var firstRound: [(String, Double)] = []
let events = load(args[3]) as! [[String: Any]]
for round in 0..<repeatCount {
for e in events {
    let league = e["league"] as! String
    let ev = LinkerEvent(id: e["id"] as! String, league: league, kickoff: fmt.date(from: e["date"] as! String)!, home: team(e["home"] as! [String: Any]), away: team(e["away"] as! [String: Any]),
                         broadcasts: (e["broadcasts"] as? [Any])?.compactMap { $0 as? String } ?? [], isNational: nationalKeys.contains { league.contains($0) })
    let w0 = wallMs(), c0 = cpuMs()
    let feeds = linker.link(ev)
    let tookCPU = cpuMs() - c0, tookWall = wallMs() - w0
    if round == 0 { firstRound.append((e["name"] as? String ?? "?", tookCPU)) } else { linkWall.append(tookWall); linkCPU.append(tookCPU) }
    if round > 0 { continue }
    results.append(["event": e, "options": feeds.map { f in
        ["key": f.key, "tier": f.tier.rawValue, "conf": f.confidence, "label": f.label, "region": f.region, "name": f.displayName, "n": f.streamIDs.count, "family": f.family,
         "why": f.evidence, "prog": f.programmeTitle ?? "", "streams": f.streamIDs]
    }])
}
}
try! JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted]).write(to: URL(fileURLWithPath: args[4]))
func pct(_ a: [Double], _ p: Double) -> Double { let s = a.sorted(); return s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count) * p))] }
let st = linker.stats
print(String(format: "index: %d streams, %d guide channels, %d programmes, %d postings, ~%.1f MB", st.streams, st.guideChannels, st.programmes, st.postings, Double(st.approximateBytes) / 1_048_576))
print(String(format: "build:  CPU best %.0f ms (median %.0f) | wall best %.0f ms   [%d runs]", buildCPU.min() ?? 0, pct(buildCPU, 0.5), buildWall.min() ?? 0, repeatCount))
for (n, ms) in firstRound.sorted(by: { $0.1 > $1.1 }).prefix(2) { print(String(format: "  first-round slowest (cold caches, CPU): %.2f ms  %@", ms, n)) }
if !linkCPU.isEmpty {
    print(String(format: "link:   CPU median %.2f ms  p95 %.2f  max %.2f | wall median %.2f  p95 %.2f   [%d links over %d events]", pct(linkCPU, 0.5), pct(linkCPU, 0.95), linkCPU.max() ?? 0, pct(linkWall, 0.5), pct(linkWall, 0.95), linkCPU.count, events.count))
}
