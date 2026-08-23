import SwiftUI

// MARK: - Recordings View

struct RecordingsView: View {
    @EnvironmentObject private var recordingService: RecordingService
    @State private var playbackChannel: Channel?
    @State private var errorMessage: String?
    @State private var showingError = false

    private var recordingNow: [RecordingJob] {
        recordingService.jobs.filter { $0.state == .recording }
            .sorted { ($0.startedAt ?? $0.scheduledStart) < ($1.startedAt ?? $1.scheduledStart) }
    }
    private var scheduled: [RecordingJob] {
        recordingService.jobs.filter { $0.state == .scheduled }
            .sorted { $0.scheduledStart < $1.scheduledStart }
    }
    private var completed: [RecordingJob] {
        recordingService.jobs.filter { $0.state == .completed }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }
    private var failedOrPartial: [RecordingJob] {
        recordingService.jobs.filter { $0.state == .failed || $0.state == .partial }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }

    private var hasAnyJobs: Bool {
        recordingService.jobs.contains { $0.state != .cancelled }
    }

    var body: some View {
        Group {
            if hasAnyJobs {
                listContent
            } else {
                emptyState
            }
        }
        .fullScreenCover(item: $playbackChannel) { ch in
            PlayerView(channel: ch)
        }
        .alert("Playback Error", isPresented: $showingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Could not open this recording.")
        }
    }

    // MARK: - List

    private var listContent: some View {
        List {
            if !recordingNow.isEmpty {
                Section("Recording Now") {
                    ForEach(recordingNow) { job in
                        RecordingJobRow(job: job)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button("Stop", role: .destructive) {
                                    recordingService.cancel(id: job.id)
                                }
                            }
                    }
                }
            }

            if !scheduled.isEmpty {
                Section("Scheduled") {
                    ForEach(scheduled) { job in
                        RecordingJobRow(job: job)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button("Cancel", role: .destructive) {
                                    recordingService.cancel(id: job.id)
                                }
                            }
                    }
                }
            }

            if !completed.isEmpty {
                Section("Completed") {
                    ForEach(completed) { job in
                        RecordingJobRow(job: job)
                            .contentShape(Rectangle())
                            .onTapGesture { Task { await play(job) } }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button("Delete", role: .destructive) {
                                    recordingService.delete(id: job.id)
                                }
                            }
                    }
                }
            }

            if !failedOrPartial.isEmpty {
                Section("Failed / Partial") {
                    ForEach(failedOrPartial) { job in
                        RecordingJobRow(job: job)
                            .onTapGesture {
                                if job.state == .partial { Task { await play(job) } }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button("Delete", role: .destructive) {
                                    recordingService.delete(id: job.id)
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "record.circle")
                .font(.system(size: 44))
                .foregroundStyle(Theme.textSecondary.opacity(0.4))
            Text("No Recordings")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("Schedule a recording from the Guide, or tap Record while watching a live channel.")
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
    }

    // MARK: - Playback

    private func play(_ job: RecordingJob) async {
        switch job.mode {
        case .local:
            guard let fileURL = recordingService.localFileURL(for: job) else {
                errorMessage = "The recording file could not be found on this device."
                showingError = true
                return
            }
            playbackChannel = Channel(
                id: "rec-\(job.id.uuidString)",
                name: job.programmeTitle,
                streamURL: fileURL,
                logoURL: job.channelLogoURL,
                group: job.channelName,
                playlistID: UUID(),
                playlistName: ""
            )

        case .providerDVR:
            guard let url = await recordingService.resolveProviderDVRURL(for: job) else {
                errorMessage = "The catch-up URL could not be resolved. The archive window may have expired, or the provider does not support timeshift playback."
                showingError = true
                return
            }
            playbackChannel = Channel(
                id: "rec-\(job.id.uuidString)",
                name: job.programmeTitle,
                streamURL: url,
                logoURL: job.channelLogoURL,
                group: job.channelName,
                playlistID: UUID(),
                playlistName: ""
            )

        case .unavailable:
            break
        }
    }
}

// MARK: - Recording Job Row

struct RecordingJobRow: View {
    let job: RecordingJob

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        HStack(spacing: 12) {
            stateIcon
            VStack(alignment: .leading, spacing: 3) {
                Text(job.programmeTitle)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(job.channelName)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                metaLine
                if let err = job.errorMessage {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red.opacity(0.85))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            modeChip
        }
        .padding(.vertical, 4)
    }

    // MARK: - Subviews

    private var stateIcon: some View {
        ZStack {
            Circle()
                .fill(stateColor.opacity(0.15))
                .frame(width: 36, height: 36)
            Image(systemName: stateSystemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(stateColor)
                .symbolEffect(.pulse, isActive: job.state == .recording)
        }
    }

    private var metaLine: some View {
        HStack(spacing: 6) {
            Text(Self.dateFmt.string(from: job.scheduledStart))
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
            dot
            Text(job.durationLabel)
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
            if let size = job.fileSizeLabel {
                dot
                Text(size)
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    @ViewBuilder
    private var modeChip: some View {
        switch job.mode {
        case .providerDVR:
            Text("DVR")
                .font(.caption2.weight(.bold))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Theme.accent.opacity(0.12), in: Capsule())
        case .local:
            Text("Local")
                .font(.caption2.weight(.bold))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Theme.surface, in: Capsule())
        case .unavailable:
            EmptyView()
        }
    }

    private var dot: some View {
        Text("·").font(.caption).foregroundStyle(Theme.textTertiary)
    }

    // MARK: - Computed

    private var stateColor: Color {
        switch job.state {
        case .scheduled:   return Theme.starting
        case .recording:   return Theme.live
        case .finalizing:  return Theme.accent
        case .completed:   return .green
        case .partial:     return .orange
        case .failed:      return .red
        case .cancelled:   return Theme.textSecondary
        }
    }

    private var stateSystemImage: String {
        switch job.state {
        case .scheduled:   return "clock"
        case .recording:   return "record.circle.fill"
        case .finalizing:  return "arrow.triangle.2.circlepath"
        case .completed:   return "checkmark"
        case .partial:     return "exclamationmark"
        case .failed:      return "xmark"
        case .cancelled:   return "minus"
        }
    }
}

// MARK: - Recording Schedule Sheet

struct RecordingScheduleSheet: View {
    let programme: EPGProgramme
    let channel: CanonicalChannel
    let onScheduled: (RecordingJob) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var recordingService: RecordingService

    @State private var startPadding = 0
    @State private var endPadding   = 0
    @State private var isScheduling = false

    private var mode: RecordingMode { recordingService.preferredMode(for: channel) }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        programmeCard
                        paddingSection
                        modeNote
                        scheduleButton
                        Spacer(minLength: 0)
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Schedule Recording")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .tint(Theme.accent)
    }

    // MARK: - Subviews

    private var programmeCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(programme.title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(channel.name)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
                Text("\(Self.timeFmt.string(from: paddedStart)) → \(Self.timeFmt.string(from: paddedEnd))")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private var paddingSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Recording Window")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)

            VStack(alignment: .leading, spacing: 8) {
                Text("Start \(startPadding == 0 ? "on time" : "\(startPadding) min early")")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                Picker("Start early", selection: $startPadding) {
                    Text("On time").tag(0)
                    Text("5 min early").tag(5)
                    Text("10 min early").tag(10)
                    Text("15 min early").tag(15)
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("End \(endPadding == 0 ? "on time" : "\(endPadding) min late")")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                Picker("End late", selection: $endPadding) {
                    Text("On time").tag(0)
                    Text("+5 min").tag(5)
                    Text("+15 min").tag(15)
                    Text("+30 min").tag(30)
                }
                .pickerStyle(.segmented)
            }
        }
    }

    @ViewBuilder
    private var modeNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: modeIcon)
                .font(.callout)
                .foregroundStyle(modeColor)
                .frame(width: 20)
            Text(modeDescription)
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(modeColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var scheduleButton: some View {
        Button {
            guard !isScheduling else { return }
            isScheduling = true
            let job = recordingService.schedule(
                programme: programme,
                channel: channel,
                startPaddingMinutes: startPadding,
                endPaddingMinutes: endPadding
            )
            dismiss()
            onScheduled(job)
        } label: {
            Group {
                if isScheduling {
                    ProgressView().tint(.white)
                } else {
                    Label("Schedule Recording", systemImage: "record.circle")
                }
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(mode == .unavailable ? Theme.textSecondary : Theme.live,
                        in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(mode == .unavailable || isScheduling)
    }

    // MARK: - Computed

    private var paddedStart: Date {
        programme.start.addingTimeInterval(-TimeInterval(startPadding * 60))
    }
    private var paddedEnd: Date {
        programme.end.addingTimeInterval(TimeInterval(endPadding * 60))
    }

    private var modeIcon: String {
        switch mode {
        case .providerDVR: return "cloud.fill"
        case .local:       return "internaldrive"
        case .unavailable: return "exclamationmark.triangle"
        }
    }
    private var modeColor: Color {
        switch mode {
        case .providerDVR: return Theme.accent
        case .local:       return Theme.starting
        case .unavailable: return .red
        }
    }
    private var modeDescription: String {
        switch mode {
        case .providerDVR:
            return "Provider DVR — your provider will archive this stream. No local storage is used. Playback is available within the catch-up retention window."
        case .local:
            return "Local recording — segments are saved to this device while StadiaTV is in the foreground. The recording will stop if the app is suspended by iOS."
        case .unavailable:
            return "Recording is not available for this channel. Enable catch-up on a compatible provider to use DVR."
        }
    }
}
