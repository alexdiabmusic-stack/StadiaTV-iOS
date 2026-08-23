import Foundation

// MARK: - Recording Mode

/// How a recording is performed. Determined at schedule time from channel capabilities.
enum RecordingMode: String, Codable, Hashable, Sendable {
    /// Provider archives the live stream server-side (e.g., Xtream with catch-up enabled).
    /// No local download; playback builds a timeshift URL via CatchupResolver at view time.
    case providerDVR

    /// HLS segments are downloaded to the device while the app is in the foreground.
    /// Recording pauses automatically if the app is suspended by iOS.
    case local

    /// Recording is not supported for this channel.
    case unavailable

    var label: String {
        switch self {
        case .providerDVR: return "Provider DVR"
        case .local:       return "Local"
        case .unavailable: return "Unavailable"
        }
    }
}

// MARK: - Recording State

enum RecordingState: String, Codable, Hashable, Sendable {
    case scheduled   // Future programme; not yet started
    case recording   // Actively running right now
    case finalizing  // Writing final output (local mode)
    case completed   // Finished successfully; available for playback
    case partial     // Stopped early: foreground suspended, storage full, or connection lost
    case failed      // Fatal error preventing any useful output
    case cancelled   // Cancelled by the user
}

// MARK: - Recurrence

struct RecordingRecurrence: Codable, Hashable, Sendable {
    enum Pattern: String, Codable, Sendable { case once, daily, weekly }

    var pattern: Pattern
    /// ISO weekday numbers (1 = Sunday … 7 = Saturday). Used when pattern == .weekly.
    var weekdays: Set<Int>

    static let once = RecordingRecurrence(pattern: .once, weekdays: [])

    var label: String {
        switch pattern {
        case .once:  return "Once"
        case .daily: return "Daily"
        case .weekly:
            let syms = Calendar.current.shortWeekdaySymbols
            let names = weekdays.sorted().compactMap { idx -> String? in
                idx >= 1 && idx <= syms.count ? syms[idx - 1] : nil
            }
            return names.isEmpty ? "Weekly" : names.joined(separator: ", ")
        }
    }
}

// MARK: - Recording Job

struct RecordingJob: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var channelID: String
    var channelName: String
    var channelLogoURL: URL?
    var programmeTitle: String
    /// Padded start time: originalStart minus startPaddingMinutes.
    var scheduledStart: Date
    /// Padded end time: originalEnd plus endPaddingMinutes.
    var scheduledEnd: Date
    /// EPG programme start, without padding.
    var originalStart: Date
    /// EPG programme end, without padding.
    var originalEnd: Date
    var startPaddingMinutes: Int
    var endPaddingMinutes: Int
    var recurrence: RecordingRecurrence
    var mode: RecordingMode
    var state: RecordingState
    /// Filename (not full path) of the recorded file, relative to the app recording directory.
    /// Stream credentials are never stored here or in any other persisted field.
    var localFilename: String?
    var fileSizeBytes: Int64?
    var errorMessage: String?
    var createdAt: Date
    var startedAt: Date?
    var completedAt: Date?

    var scheduledDuration: TimeInterval { scheduledEnd.timeIntervalSince(scheduledStart) }

    var durationLabel: String {
        let total = max(0, Int(scheduledDuration))
        let h = total / 3600; let m = (total % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m) min"
    }

    var fileSizeLabel: String? {
        guard let bytes = fileSizeBytes, bytes > 0 else { return nil }
        let gb = Double(bytes) / 1_073_741_824
        let mb = Double(bytes) / 1_048_576
        return gb >= 1 ? String(format: "%.1f GB", gb) : String(format: "%.0f MB", mb)
    }

    static func == (lhs: RecordingJob, rhs: RecordingJob) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
