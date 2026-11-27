import BannerCore
import SwiftUI

/// Live TV: channel browser (favourites, recents, groups, search) with what is on now.
struct LiveTvView: View {
    @EnvironmentObject private var live: LiveTvModel
    @EnvironmentObject private var sources: LiveTvSources
    @EnvironmentObject private var router: Router
    @State private var query = ""
    @State private var group = "All"

    private var filtered: [ChannelItem] {
        live.channels.filter { c in
            switch group {
            case "All": true
            case "Favorites": live.favorites.contains(c.id)
            case "Recent": live.recents.contains(c.id)
            default: c.group == group
            }
        }
        .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var ordered: [ChannelItem] {
        group == "Recent" ? filtered.sorted { (live.recents.firstIndex(of: $0.id) ?? 99) < (live.recents.firstIndex(of: $1.id) ?? 99) } : filtered
    }

    var startOnGuide = false
    @State private var guideMode: Bool? = nil
    private var showsGuide: Bool { guideMode ?? startOnGuide }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !sources.isConfigured { NoSourcesView() }
            else if showsGuide { GuideView() }
            else {
                if let error = live.error, live.channels.isEmpty { Text(error).font(.jb(15)).foregroundStyle(Color(red: 1, green: 0.45, blue: 0.45)).padding(Theme.gutter) }
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320, maximum: 420), spacing: 16)], spacing: 16) {
                        ForEach(ordered) { channel in
                            Button { play(channel) } label: { ChannelRow(channel: channel) }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button(live.favorites.contains(channel.id) ? "Remove from Favorites" : "Add to Favorites") { live.toggleFavorite(channel) }
                                }
                        }
                    }
                    .padding(.horizontal, Theme.gutter).padding(.vertical, 12).padding(.bottom, 50)
                }
            }
        }
        .padding(.top, 84)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Text("Live TV").font(.jb(40, .bold))
                if live.isLoading { ProgressView().controlSize(.small) }
                Spacer()
                HStack(spacing: 8) {
                    Chip(title: "Channels", selected: !showsGuide) { guideMode = false }
                    Chip(title: "Guide", selected: showsGuide) { guideMode = true }
                }
                if !showsGuide {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Theme.textMuted)
                        TextField("Search channels", text: $query).textFieldStyle(.plain).font(.jb(15))
                    }
                    .padding(.horizontal, 16).frame(width: 240, height: 40).background(Color.white.opacity(0.08), in: Capsule())
                    Button { live.refresh() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(GlassCircleButtonStyle(size: 40)).help("Reload channels")
                }
            }
            if !showsGuide && sources.isConfigured {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(["All", "Favorites", "Recent"] + live.groups, id: \.self) { name in Chip(title: name, selected: group == name) { group = name } }
                    }
                }
            }
        }
        .padding(.horizontal, Theme.gutter).padding(.bottom, 8)
    }

    private func play(_ channel: ChannelItem) {
        guard let url = channel.url, url.scheme == "http" || url.scheme == "https" else { return }
        MacBridge.shared.markLiveWatched(channelId: channel.id)
        let ref = TitleRef(type: "tv", id: channel.id, name: channel.name, poster: channel.logo)
        let source = SourceOption(id: channel.id, addonId: "live", title: channel.name, detail: nil, url: url, headers: channel.headers, kind: .direct, subtitles: [])
        router.play(PlaybackRequest(ref: ref, videoId: channel.id, title: channel.name, subtitle: live.nowNext(channel).now?.title,
                                    source: source, startAt: nil, next: nil, isLive: true))
    }
}

private struct ChannelRow: View {
    let channel: ChannelItem
    @EnvironmentObject private var live: LiveTvModel

    var body: some View {
        let info = live.nowNext(channel)
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surfaceRaised)
                if let logo = channel.logo {
                    AsyncImage(url: logo) { phase in if let image = phase.image { image.resizable().aspectRatio(contentMode: .fit).padding(6) } }
                } else { Image(systemName: "tv").foregroundStyle(Theme.textSecondary) }
            }
            .frame(width: 64, height: 48)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(channel.name).font(.jb(16, .semibold)).lineLimit(1)
                    if live.favorites.contains(channel.id) { Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow) }
                }
                if let now = info.now {
                    Text(now.title).font(.jb(13)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    GeometryReader { g in
                        ZStack(alignment: .leading) { Color.white.opacity(0.15); Color.white.frame(width: g.size.width * now.fraction) }
                    }.frame(height: 3).clipShape(Capsule())
                } else {
                    Text(channel.group).font(.jb(13)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusPoster + 4, style: .continuous))
        .contentShape(Rectangle())
        .hoverLift(1.02)
    }
}

private struct NoSourcesView: View {
    @EnvironmentObject private var router: Router
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "tv").font(.system(size: 44)).foregroundStyle(Theme.accent)
            Text("Add your IPTV source").font(.jb(26, .bold))
            Text("Live TV works with M3U playlists and Xtream logins. Add yours in Settings; it stays on this Mac.")
                .font(.jb(15)).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The programme guide: channels down the side, time across, scrolling together.
struct GuideView: View {
    @EnvironmentObject private var live: LiveTvModel
    @EnvironmentObject private var sources: LiveTvSources
    @EnvironmentObject private var router: Router
    @State private var query = ""
    @State private var anchor = Date().addingTimeInterval(-30 * 60).roundedDown(to: 1800)

    private let pointsPerMinute: CGFloat = 5
    private let rowHeight: CGFloat = 56
    private let hours = 6

    private var channels: [ChannelItem] {
        let withGuide = live.channels.filter { !live.programs($0).isEmpty }
        let base = withGuide.isEmpty ? live.channels : withGuide
        return query.isEmpty ? base : base.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if live.isGuideLoading { ProgressView().controlSize(.small); Text("Loading guide").font(.jb(14)).foregroundStyle(Theme.textSecondary) }
                Spacer()
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.textMuted)
                    TextField("Search channels", text: $query).textFieldStyle(.plain).font(.jb(15))
                }
                .padding(.horizontal, 16).frame(width: 240, height: 40).background(Color.white.opacity(0.08), in: Capsule())
            }
            .padding(.horizontal, Theme.gutter).padding(.bottom, 12)
            if !sources.isConfigured { NoGuideSources() }
            else if live.guideLoaded || !live.isGuideLoading {
                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 0) { Color.clear.frame(width: 190, height: 26); timeRuler }
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(channels.prefix(300)) { channel in
                                HStack(spacing: 0) { channelCell(channel); guideRow(channel) }
                            }
                        }
                    }
                    .padding(.horizontal, Theme.gutter)
                    .overlay(alignment: .topLeading) { nowLine }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var width: CGFloat { CGFloat(hours * 60) * pointsPerMinute }

    private var timeRuler: some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<(hours * 2), id: \.self) { i in
                Text(anchor.addingTimeInterval(Double(i) * 1800).formatted(date: .omitted, time: .shortened))
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                    .offset(x: CGFloat(i * 30) * pointsPerMinute + 6)
            }
        }
        .frame(width: width, height: 26, alignment: .topLeading)
    }

    private var nowLine: some View {
        let x = CGFloat(Date().timeIntervalSince(anchor) / 60) * pointsPerMinute + 190 + Theme.gutter
        return Rectangle().fill(Color.red.opacity(0.8)).frame(width: 2).offset(x: x).allowsHitTesting(false)
    }

    private func guideRow(_ channel: ChannelItem) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(live.programs(channel).filter { $0.end > anchor && $0.start < anchor.addingTimeInterval(Double(hours) * 3600) }, id: \.self) { p in
                let start = max(p.start.timeIntervalSince(anchor) / 60, 0)
                let end = min(p.end.timeIntervalSince(anchor) / 60, Double(hours * 60))
                Button { play(channel) } label: {
                    Text(p.title).font(.jb(13, .semibold)).lineLimit(2).padding(.horizontal, 8).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .background(p.start <= Date() && p.end > Date() ? Theme.surfaceRaised : Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .frame(width: max(CGFloat(end - start) * pointsPerMinute - 3, 20), height: rowHeight)
                .offset(x: CGFloat(start) * pointsPerMinute)
                .help(p.title)
            }
        }
        .frame(width: width, height: rowHeight, alignment: .topLeading)
    }

    private func channelCell(_ channel: ChannelItem) -> some View {
        HStack(spacing: 8) {
            if let logo = channel.logo { AsyncImage(url: logo) { p in if let i = p.image { i.resizable().aspectRatio(contentMode: .fit) } }.frame(width: 34, height: 26) }
            Text(channel.name).font(.callout.weight(.semibold)).lineLimit(1)
        }
        .padding(.horizontal, 10).frame(width: 190, height: rowHeight, alignment: .leading)
    }

    private func play(_ channel: ChannelItem) {
        guard let url = channel.url else { return }
        MacBridge.shared.markLiveWatched(channelId: channel.id)
        let ref = TitleRef(type: "tv", id: channel.id, name: channel.name, poster: channel.logo)
        let source = SourceOption(id: channel.id, addonId: "live", title: channel.name, detail: nil, url: url, headers: channel.headers, kind: .direct, subtitles: [])
        router.play(PlaybackRequest(ref: ref, videoId: channel.id, title: channel.name, subtitle: nil, source: source, startAt: nil, next: nil, isLive: true))
    }
}

private struct NoGuideSources: View {
    var body: some View {
        Text("Add an IPTV source in Settings to see the guide.").font(.jb(15)).foregroundStyle(Theme.textSecondary).padding(Theme.gutter)
    }
}

extension Date {
    func roundedDown(to seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: (timeIntervalSince1970 / seconds).rounded(.down) * seconds) }
}
