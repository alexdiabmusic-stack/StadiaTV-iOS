import SwiftUI

struct F1RaceControlView: View {
    let messages: [F1RaceControlMessage]
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 18) {
            if messages.isEmpty { ContentUnavailableView("No race-control messages", systemImage: "flag") }
            ForEach(messages.reversed()) { message in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label(message.flag ?? message.category, systemImage: message.important ? "exclamationmark.triangle.fill" : "flag")
                        Spacer()
                        if let time = message.time { Text(time, style: .time).foregroundStyle(.secondary) }
                    }.font(.caption.bold())
                    Text(message.text).font(message.important ? .headline : .body)
                    if let scope = message.scope { Text(scope).font(.caption).foregroundStyle(.secondary) }
                }.padding(.vertical, 6).accessibilityElement(children: .combine)
                Divider()
            }
        }.padding()
    }
}

struct F1TeamRadioView: View {
    let state: F1SessionState
    @EnvironmentObject private var audio: PodcastStore
    @State private var driver = "all"
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView(.horizontal) {
                HStack {
                    Button("All") { driver = "all" }
                    ForEach(state.drivers) { row in Button(row.driver.tla) { driver = row.id } }
                }.buttonStyle(.bordered)
            }
            if state.radio.isEmpty { ContentUnavailableView("No team radio available", systemImage: "waveform") }
            ForEach(state.radio.filter { driver == "all" || $0.driverNumber == driver }.reversed()) { message in
                let identity = state.drivers.first { $0.id == message.driverNumber }?.driver
                HStack {
                    VStack(alignment: .leading) {
                        Text(identity?.name ?? "Team radio").font(.headline)
                        Text(identity?.team ?? "").font(.caption).foregroundStyle(.secondary)
                        if let time = message.time { Text(time, style: .time).font(.caption) }
                    }
                    Spacer()
                    if let url = message.url {
                        Button {
                            if audio.nowPlaying?.id == message.id { audio.togglePlayPause() }
                            else {
                                audio.play(PodcastEpisode(id: message.id, podcastID: state.identity, podcastTitle: state.meeting, podcastArtworkURL: identity?.headshot, title: "\(identity?.name ?? "Formula 1") · Team radio", episodeDescription: "", audioURL: url, duration: 0, publishedAt: message.time ?? state.updatedAt, feedURL: url))
                            }
                        } label: {
                            Label(audio.nowPlaying?.id == message.id && audio.isPlaying ? "Pause" : "Play", systemImage: audio.nowPlaying?.id == message.id && audio.isPlaying ? "pause.fill" : "play.fill").frame(minHeight: 44)
                        }.buttonStyle(.bordered)
                    } else { Text("Recording unavailable").font(.caption) }
                }.padding(.vertical, 8)
                Divider()
            }
        }.padding()
    }
}
