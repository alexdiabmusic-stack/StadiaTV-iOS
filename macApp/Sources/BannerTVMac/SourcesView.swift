import AppKit
import SwiftUI

/// Pick where to play from: every installed add-on that serves streams for this title, answering as they arrive.
struct SourcesView: View {
    let target: SourceTarget
    @StateObject private var model = SourcesModel()
    @EnvironmentObject private var router: Router
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.title).font(.jb(22, .bold))
                    if let s = target.subtitle { Text(s).font(.jb(14)).foregroundStyle(Theme.textSecondary) }
                }
                Spacer()
                if model.isLoading { ProgressView().controlSize(.small) }
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(GlassCircleButtonStyle(size: 36)).keyboardShortcut(.cancelAction)
            }
            .padding(24)
            Divider().opacity(0.3)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20, pinnedViews: []) {
                    if model.groups.isEmpty && !model.isLoading {
                        Text("None of your installed add-ons provides sources for this title.").font(.jb(15)).foregroundStyle(Theme.textSecondary)
                    }
                    ForEach(model.groups) { group in groupView(group) }
                }
                .padding(24)
            }
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 460, idealHeight: 620)
        .background(Theme.background)
        .task { model.load(type: target.ref.type, videoId: target.videoId) }
        .onDisappear { model.cancel() }
        .onChange(of: model.groups) { _, groups in
            if let addon = target.autoPickAddon {
                if let first = groups.first(where: { $0.id == addon })?.options.first(where: { $0.kind == .direct }) { choose(first) }
                else if !model.isLoading, let any = groups.flatMap(\.options).first(where: { $0.kind == .direct }) { choose(any) }
                return
            }
            guard DebugHarness.autoSource, let first = groups.flatMap(\.options).first(where: { $0.kind == .direct }) else { return }
            choose(first)
        }
    }

    @ViewBuilder private func groupView(_ group: SourceGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(group.name).font(.jb(17, .semibold))
                if group.isLoading { ProgressView().controlSize(.mini) }
                else if let e = group.error { Text(e).font(.jb(12)).foregroundStyle(.red) }
                else { Text("\(group.options.count)").font(.jb(12)).foregroundStyle(Theme.textSecondary) }
            }
            ForEach(group.options) { option in
                Button { choose(option) } label: { row(option) }
                    .buttonStyle(.plain)
                    .disabled(option.kind == .torrent || option.kind == .unsupported)
            }
        }
    }

    private func row(_ option: SourceOption) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(option.title).font(.jb(15, .semibold)).lineLimit(2)
                if let d = option.detail { Text(d).font(.jb(13)).foregroundStyle(Theme.textSecondary).lineLimit(3) }
            }
            Spacer()
            switch option.kind {
            case .direct: Image(systemName: "play.fill")
            case .external: Image(systemName: "arrow.up.right.square")
            case .torrent: Text("Torrent").font(.jb(12)).foregroundStyle(Theme.textSecondary)
            case .unsupported: Text("Unavailable").font(.jb(12)).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .opacity(option.kind == .direct || option.kind == .external ? 1 : 0.5)
        .contentShape(Rectangle())
    }

    @State private var chosen = false

    private func choose(_ option: SourceOption) {
        guard !chosen, let url = option.url, url.scheme == "http" || url.scheme == "https" else { return }
        chosen = true
        if option.kind == .external { NSWorkspace.shared.open(url); return }
        router.play(PlaybackRequest(ref: target.ref, videoId: target.videoId, title: target.title,
                                    subtitle: target.subtitle, source: option, startAt: target.startAt, next: target.next, upcoming: target.upcoming,
                                    season: target.season, episode: target.episode))
        dismiss()
    }
}
