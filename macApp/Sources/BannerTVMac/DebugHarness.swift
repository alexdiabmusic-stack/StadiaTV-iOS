import AppKit
import Foundation

/// Launch flags for automated checks. None of them change normal use.
///  --section <home|explore|search|library|liveTV|guide|sports|settings|playbackTest>  open that section first
///  --snapshot <path.png> [--snapshot-delay <seconds>]  save the window's contents to a PNG and quit
///  --selftest-addon <manifest url>                      install an add-on through the core and print what loaded
enum DebugHarness {
    static func value(after flag: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
    }

    static var section: AppSection? { value(after: "--section").flatMap(AppSection.init(rawValue:)) }
    /// `--open movie:tt0111161` pushes that title's Details page at launch.
    static var openRef: TitleRef? {
        guard let v = value(after: "--open"), let i = v.firstIndex(of: ":") else { return nil }
        return TitleRef(type: String(v[..<i]), id: String(v[v.index(after: i)...]), name: "", poster: nil)
    }
    /// `--auto-source` plays the first direct source as soon as one appears in the sources sheet.
    static var autoSource: Bool { CommandLine.arguments.contains("--auto-source") }
    /// `--press-play` taps the primary Play button on Details at launch.
    static var pressPlay: Bool { CommandLine.arguments.contains("--press-play") }

    /// `--anonymous` continues without an account as soon as the sign-in screen appears.
    static var anonymous: Bool { CommandLine.arguments.contains("--anonymous") }

    /// `--open-collection <id>` pushes that Explore collection's page at launch.
    static var openCollection: String? { value(after: "--open-collection") }

    /// `--open-game <id>` / `--open-league <id>` push a Sports game or league page at launch.
    /// `--open-serializd` / `--open-serializd-advanced` push the Serializd pages at launch.
    static var openSerializd: Bool { CommandLine.arguments.contains("--open-serializd") }
    static var openSerializdAdvanced: Bool { CommandLine.arguments.contains("--open-serializd-advanced") }
    /// `--open-letterboxd` / `--open-letterboxd-advanced` push the Letterboxd pages at launch.
    static var openLetterboxd: Bool { CommandLine.arguments.contains("--open-letterboxd") }
    static var openLetterboxdAdvanced: Bool { CommandLine.arguments.contains("--open-letterboxd-advanced") }
    /// `--open-letterboxd-signin` opens the Letterboxd sign-in sheet at launch and logs the pages it reaches (addresses only, never cookies).
    static var openLetterboxdSignIn: Bool { CommandLine.arguments.contains("--open-letterboxd-signin") }
    static var openGame: String? { value(after: "--open-game") }
    static var openLeague: String? { value(after: "--open-league") }
    /// `--open-first-game` opens the first game the Sports page lists (automated checks).
    /// `--play-first-stream` starts the best stream on a Sports game page as soon as one is listed.
    static var playFirstStream: Bool { CommandLine.arguments.contains("--play-first-stream") }
    /// `--league-tab Table|Teams` selects that tab on a Sports league page.
    static var leagueTab: String? { value(after: "--league-tab") }
    static var openFirstGame: Bool { CommandLine.arguments.contains("--open-first-game") }

    static var snapshotPath: String? { value(after: "--snapshot") }
    static var snapshotDelay: Double { value(after: "--snapshot-delay").flatMap(Double.init) ?? 8 }

    /// Renders the window's view hierarchy (not video or Metal layers) to a PNG, then quits.
    @MainActor
    static func snapshotAndQuit() async {
        guard let path = snapshotPath else { return }
        // `--window 1440x1900` sizes the window first, so a long page can be captured in one image.
        if let spec = value(after: "--window")?.split(separator: "x").compactMap({ Double($0) }), spec.count == 2,
           let window = NSApp.windows.first(where: { $0.contentView != nil && $0.isVisible }) {
            window.setFrame(NSRect(x: 0, y: 0, width: spec[0], height: spec[1]), display: true)
        }
        try? await Task.sleep(nanoseconds: UInt64(snapshotDelay * 1_000_000_000))
        // `--scroll 900` scrolls the page's main scroll view down that far before capturing.
        if let amount = value(after: "--scroll").flatMap(Double.init), let root = NSApp.windows.first(where: { $0.contentView != nil && $0.isVisible })?.contentView {
            var best: NSScrollView?
            func walk(_ v: NSView) {
                if let sv = v as? NSScrollView, sv.documentView.map({ $0.frame.height > (best?.documentView?.frame.height ?? 0) }) == true, sv.frame.width > 600 { best = sv }
                v.subviews.forEach(walk)
            }
            walk(root)
            if let sv = best { sv.contentView.scroll(to: NSPoint(x: 0, y: amount)); sv.reflectScrolledClipView(sv.contentView) }
            try? await Task.sleep(nanoseconds: 2_500_000_000)
        }
        // `--hscroll 99999` scrolls every horizontal row to its far end (twice, so endless rows can add titles in between).
        if let amount = value(after: "--hscroll").flatMap(Double.init), let root = NSApp.windows.first(where: { $0.contentView != nil && $0.isVisible })?.contentView {
            for _ in 0..<3 {
                func walk(_ v: NSView) {
                    if let sv = v as? NSScrollView, let doc = sv.documentView, doc.frame.width > sv.frame.width + 50 {
                        let x = max(0, min(amount, doc.frame.width - sv.frame.width))
                        sv.contentView.scroll(to: NSPoint(x: x, y: 0)); sv.reflectScrolledClipView(sv.contentView)
                    }
                    v.subviews.forEach(walk)
                }
                walk(root)
                try? await Task.sleep(nanoseconds: 6_000_000_000)
            }
        }
        guard let window = NSApp.windows.first(where: { $0.contentView != nil && $0.isVisible }),
              let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            FileHandle.standardError.write(Data("[snapshot] no window\n".utf8)); exit(2)
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
            FileHandle.standardError.write(Data("[snapshot] wrote \(path) \(Int(view.bounds.width))x\(Int(view.bounds.height))\n".utf8))
        }
        exit(0)
    }
}
