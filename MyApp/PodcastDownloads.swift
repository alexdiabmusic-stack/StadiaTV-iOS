import Foundation
import Observation

/// User-initiated downloads of regular audio files. HLS requires a separate asset-download flow.
@MainActor
@Observable
final class PodcastDownloads {
    struct Download: Codable, Identifiable {
        let episode: PodcastEpisode
        let filename: String
        let byteCount: Int64
        var id: String { episode.id }
    }

    private(set) var downloads: [Download] = []
    private(set) var downloadingIDs = Set<String>()
    private(set) var errors: [String: String] = [:]
    var allowsCellular: Bool {
        didSet { UserDefaults.standard.set(allowsCellular, forKey: "bannertv.podcasts.downloadCellular") }
    }
    var storageLimitMB: Int {
        didSet { UserDefaults.standard.set(storageLimitMB, forKey: "bannertv.podcasts.downloadLimitMB") }
    }
    private let root: URL
    private let manifestKey = "bannertv.podcasts.downloads.v1"

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        root = base.appendingPathComponent("PodcastDownloads", isDirectory: true)
        allowsCellular = UserDefaults.standard.bool(forKey: "bannertv.podcasts.downloadCellular")
        let savedLimit = UserDefaults.standard.integer(forKey: "bannertv.podcasts.downloadLimitMB")
        storageLimitMB = savedLimit > 0 ? savedLimit : 1024
        if let data = UserDefaults.standard.data(forKey: manifestKey),
           let entries = try? JSONDecoder().decode([Download].self, from: data) {
            downloads = entries.filter {
                $0.filename == URL(fileURLWithPath: $0.filename).lastPathComponent &&
                FileManager.default.fileExists(atPath: root.appendingPathComponent($0.filename).path)
            }
        }
    }

    func localURL(for episode: PodcastEpisode) -> URL? {
        guard let saved = downloads.first(where: { $0.id == episode.id }) else { return nil }
        let url = root.appendingPathComponent(saved.filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func download(_ episode: PodcastEpisode) async {
        guard localURL(for: episode) == nil, !downloadingIDs.contains(episode.id) else { return }
        guard !episode.isVideo, ["https", "http"].contains(episode.audioURL.scheme?.lowercased() ?? ""),
              episode.audioURL.pathExtension.lowercased() != "m3u8" else {
            errors[episode.id] = String(localized: "This source does not support audio file downloads.")
            return
        }
        downloadingIDs.insert(episode.id)
        errors[episode.id] = nil
        defer {
            downloadingIDs.remove(episode.id)
            NotificationCenter.default.post(name: .bannerAudioLibraryChanged, object: nil)
        }
        do {
            var request = URLRequest(url: episode.audioURL)
            request.allowsCellularAccess = allowsCellular
            let (temporary, response) = try await URLSession.shared.download(for: request)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            let mime = (response.mimeType ?? "").lowercased()
            guard mime.hasPrefix("audio/") || mime == "application/octet-stream" else {
                throw URLError(.cannotDecodeContentData)
            }
            let size = (try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.int64Value ?? 0
            let used = downloads.reduce(Int64(0)) { $0 + $1.byteCount }
            guard size > 0, used + size <= Int64(max(128, storageLimitMB)) * 1024 * 1024 else {
                errors[episode.id] = String(localized: "Download storage limit reached.")
                return
            }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let extensions: [String: String] = ["audio/mpeg": "mp3", "audio/mp4": "m4a", "audio/aac": "aac",
                                               "audio/x-m4a": "m4a", "audio/wav": "wav", "audio/ogg": "ogg"]
            let ext = extensions[mime] ?? "audio"
            let filename = UUID().uuidString + "." + ext
            var destination = root.appendingPathComponent(filename)
            try FileManager.default.moveItem(at: temporary, to: destination)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? destination.setResourceValues(values)
            downloads.append(Download(episode: episode, filename: filename, byteCount: size))
            persist()
        } catch is CancellationError {
            return
        } catch {
            errors[episode.id] = String(localized: "Download failed. Check your connection and try again.")
        }
    }

    func remove(_ episode: PodcastEpisode) {
        guard let entry = downloads.first(where: { $0.id == episode.id }) else { return }
        do {
            let url = root.appendingPathComponent(entry.filename)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            downloads.removeAll { $0.id == episode.id }
            persist()
        } catch {
            errors[episode.id] = String(localized: "Unable to remove this download.")
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(downloads) { UserDefaults.standard.set(data, forKey: manifestKey) }
        NotificationCenter.default.post(name: .bannerAudioLibraryChanged, object: nil)
    }
}
