import Foundation
import Combine
import UserNotifications

/// Unified recording service for provider DVR and foreground-local HLS recording.
///
/// Provider DVR (Xtream channels with catch-up): tracks the scheduled window and
/// builds a timeshift URL at playback time. No download happens locally.
///
/// Local HLS: downloads MPEG-TS segments to the device via HLSRecorder while the
/// app is in the foreground. If the app is suspended, recording pauses and the job
/// transitions to .partial. Scheduled multi-hour recordings are NOT guaranteed to
/// complete in the background on iOS/tvOS.
///
/// Security: stream credentials are never stored in persisted RecordingJob data.
@MainActor
final class RecordingService: ObservableObject {
    static let shared = RecordingService()

    @Published private(set) var jobs: [RecordingJob] = []

    private let storeURL: URL
    private let notifCenter = UNUserNotificationCenter.current()
    private var stateTask: Task<Void, Never>?
    private var activeRecorders: [UUID: HLSRecorder] = [:]

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("StadiaTV", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storeURL = dir.appendingPathComponent("recordings.json")
        load()
        startStateLoop()
    }

    // MARK: - Mode detection

    func preferredMode(for channel: CanonicalChannel) -> RecordingMode {
        guard channel.primaryStream != nil || !channel.fallbackStreams.isEmpty else {
            return .unavailable
        }
        return channel.hasCatchup ? .providerDVR : .local
    }

    // MARK: - Schedule from EPG

    @discardableResult
    func schedule(
        programme: EPGProgramme,
        channel: CanonicalChannel,
        startPaddingMinutes: Int = 0,
        endPaddingMinutes: Int = 0
    ) -> RecordingJob {
        let paddedStart = programme.start.addingTimeInterval(-TimeInterval(startPaddingMinutes * 60))
        let paddedEnd   = programme.end.addingTimeInterval(TimeInterval(endPaddingMinutes * 60))
        let mode = preferredMode(for: channel)
        let now  = Date()
        let immediate = paddedStart <= now

        var job = RecordingJob(
            id: UUID(),
            channelID: channel.id,
            channelName: channel.name,
            channelLogoURL: channel.effectiveLogoURL,
            programmeTitle: programme.title,
            scheduledStart: paddedStart,
            scheduledEnd: paddedEnd,
            originalStart: programme.start,
            originalEnd: programme.end,
            startPaddingMinutes: startPaddingMinutes,
            endPaddingMinutes: endPaddingMinutes,
            recurrence: .once,
            mode: mode,
            state: immediate ? .recording : .scheduled,
            createdAt: now
        )
        if immediate { job.startedAt = now }

        jobs.append(job)
        save()

        if immediate, mode == .local {
            let jobID = job.id
            Task { await self.beginLocalRecording(jobID: jobID) }
        } else if !immediate, mode == .local {
            scheduleLocalRecordingReminder(for: job)
        }
        return job
    }

    // MARK: - Custom recording (from manual entry, no EPGProgramme required)

    @discardableResult
    func scheduleCustom(
        channelID: String,
        channelName: String,
        logoURL: URL?,
        title: String,
        start: Date,
        end: Date,
        startPaddingMinutes: Int = 0,
        endPaddingMinutes: Int = 0,
        recurrence: RecordingRecurrence = .once
    ) -> RecordingJob {
        let paddedStart = start.addingTimeInterval(-TimeInterval(startPaddingMinutes * 60))
        let paddedEnd   = end.addingTimeInterval(TimeInterval(endPaddingMinutes * 60))
        // Custom recording always defaults to providerDVR — stream URL lookup at start time
        // from LiveChannelStore; local mode also works via tick() when window begins.
        let job = RecordingJob(
            id: UUID(),
            channelID: channelID,
            channelName: channelName,
            channelLogoURL: logoURL,
            programmeTitle: title,
            scheduledStart: paddedStart,
            scheduledEnd: paddedEnd,
            originalStart: start,
            originalEnd: end,
            startPaddingMinutes: startPaddingMinutes,
            endPaddingMinutes: endPaddingMinutes,
            recurrence: recurrence,
            mode: .providerDVR,
            state: paddedStart <= Date() ? .recording : .scheduled,
            createdAt: Date()
        )
        jobs.append(job)
        save()
        return job
    }

    // MARK: - Job management

    func cancel(id: UUID) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        if jobs[idx].state == .recording {
            let recorder = activeRecorders.removeValue(forKey: id)
            Task { await recorder?.stop() }
        }
        cancelLocalRecordingReminder(for: id)
        jobs[idx].state = .cancelled
        save()
    }

    func delete(id: UUID) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        let job = jobs[idx]
        if let filename = job.localFilename {
            let fileURL = recordingDirectory().appendingPathComponent(filename)
            try? FileManager.default.removeItem(at: fileURL)
        }
        cancelLocalRecordingReminder(for: id)
        jobs.remove(at: idx)
        save()
    }

    // MARK: - Playback helpers

    /// Returns the local file URL for a completed local recording, or nil if the file is missing.
    func localFileURL(for job: RecordingJob) -> URL? {
        guard job.mode == .local, let filename = job.localFilename else { return nil }
        let url = recordingDirectory().appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Builds a provider timeshift URL for a completed providerDVR job.
    /// The stream URL is looked up at runtime from LiveChannelStore — never stored in the job.
    func resolveProviderDVRURL(for job: RecordingJob) async -> URL? {
        guard job.mode == .providerDVR else { return nil }
        guard let liveChannel = try? await LiveChannelStore.shared.channel(id: job.channelID),
              let stream = liveChannel.primaryStream else { return nil }
        let resolver = CatchupResolver()
        return try? resolver.resolveXtreamArchive(
            streamURL: stream.streamURL,
            start: job.originalStart,
            end: job.originalEnd
        )
    }

    // MARK: - State loop

    private func startStateLoop() {
        stateTask?.cancel()
        stateTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func tick() {
        let now = Date()
        var dirty = false

        for i in jobs.indices {
            switch jobs[i].state {

            case .scheduled where jobs[i].scheduledStart <= now:
                jobs[i].state    = .recording
                jobs[i].startedAt = now
                dirty = true
                if jobs[i].mode == .local {
                    let jobID = jobs[i].id
                    Task { await self.beginLocalRecording(jobID: jobID) }
                }

            case .recording where jobs[i].scheduledEnd <= now:
                if jobs[i].mode == .providerDVR {
                    jobs[i].state      = .completed
                    jobs[i].completedAt = now
                    dirty = true
                } else if jobs[i].mode == .local {
                    // Stop the recorder; finalizeLocalJob will set the completed state.
                    let recorder = activeRecorders[jobs[i].id]
                    let jobID = jobs[i].id
                    Task {
                        await recorder?.stop()
                        await self.finalizeLocalJob(jobID: jobID)
                    }
                }

            default:
                break
            }
        }

        if dirty { save() }
    }

    // MARK: - Local HLS recording

    private func beginLocalRecording(jobID: UUID) async {
        guard let channelID = jobs.first(where: { $0.id == jobID && $0.state == .recording })?.channelID else { return }
        guard let liveChannel = try? await LiveChannelStore.shared.channel(id: channelID),
              let streamURL = liveChannel.primaryStream?.streamURL else {
            update(id: jobID, state: .failed, error: "Stream not available for this channel.")
            return
        }

        let filename  = "rec-\(jobID.uuidString).ts"
        let outputURL = recordingDirectory().appendingPathComponent(filename)
        updateFilename(id: jobID, filename: filename)

        let recorder = HLSRecorder()
        activeRecorders[jobID] = recorder

        do {
            try await recorder.start(masterPlaylistURL: streamURL, outputURL: outputURL)
        } catch HLSRecorder.RecorderError.storageFull {
            update(id: jobID, state: .partial, error: "Recording stopped: not enough storage space.")
        } catch HLSRecorder.RecorderError.connectionLimited {
            update(id: jobID, state: .partial, error: "Provider connection limit reached. Reduce the number of active streams.")
        } catch HLSRecorder.RecorderError.connectionLost {
            update(id: jobID, state: .partial, error: "Recording stopped: the connection to the stream was lost.")
        } catch HLSRecorder.RecorderError.incompatibleFormat {
            update(id: jobID, state: .failed, error: "This channel uses fMP4/CMAF segments which cannot be recorded locally. Use a provider with catch-up/DVR enabled instead.")
        } catch {
            update(id: jobID, state: .partial, error: error.localizedDescription)
        }

        activeRecorders.removeValue(forKey: jobID)
        await finalizeLocalJob(jobID: jobID)
    }

    private func finalizeLocalJob(jobID: UUID) async {
        guard let idx = jobs.firstIndex(where: { $0.id == jobID }),
              jobs[idx].state == .recording else { return }

        jobs[idx].state = .finalizing
        save()

        if let filename = jobs[idx].localFilename {
            let fileURL = recordingDirectory().appendingPathComponent(filename)
            if let attr = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
               let size = attr[.size] as? Int64, size > 0 {
                jobs[idx].fileSizeBytes = size
                jobs[idx].state = .completed
            } else {
                jobs[idx].state = .partial
            }
        } else {
            jobs[idx].state = .partial
        }
        jobs[idx].completedAt = Date()
        save()
    }

    // MARK: - Notifications (foreground reminder for local recordings)

    private func scheduleLocalRecordingReminder(for job: RecordingJob) {
        #if !os(tvOS)
        let fireDate = job.scheduledStart.addingTimeInterval(-60)
        guard fireDate > Date() else { return }

        let content = UNMutableNotificationContent()
        content.title = "Recording starting soon"
        content.body  = "\(job.programmeTitle) on \(job.channelName) — keep StadiaTV open to record."
        content.sound = .default
        content.userInfo = [
            "stadiatv_type": "recording_reminder",
            "jobID": job.id.uuidString
        ]
        let comps   = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(
            identifier: notifID(for: job.id),
            content: content,
            trigger: trigger
        )
        Task { try? await notifCenter.add(request) }
        #endif
    }

    private func cancelLocalRecordingReminder(for id: UUID) {
        notifCenter.removePendingNotificationRequests(withIdentifiers: [notifID(for: id)])
    }

    private func notifID(for id: UUID) -> String { "stadiatv.rec.\(id.uuidString)" }

    // MARK: - Internal helpers

    private func update(id: UUID, state: RecordingState, error: String? = nil) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[idx].state = state
        if let error { jobs[idx].errorMessage = error }
        save()
    }

    private func updateFilename(id: UUID, filename: String) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[idx].localFilename = filename
        save()
    }

    func recordingDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("StadiaTV/Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([RecordingJob].self, from: data) else { return }
        let now = Date()
        // Resolve final state for jobs that were recording when the app was killed.
        jobs = decoded.map { job in
            var j = job
            if j.state == .recording, j.scheduledEnd < now {
                j.state      = j.mode == .providerDVR ? .completed : .partial
                j.completedAt = j.scheduledEnd
            }
            return j
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(jobs) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
