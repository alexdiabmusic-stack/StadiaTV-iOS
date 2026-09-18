import Foundation

func patchFile(_ path: String, search: String, replace: String) {
    let content = try! String(contentsOfFile: path)
    let newContent = content.replacingOccurrences(of: search, with: replace)
    try! newContent.write(toFile: path, atomically: true, encoding: .utf8)
}

patchFile("MyApp/EPGRepository.swift",
    search: "    private var epgpwPrefetchTasks: [String: Task<Void, Never>] = [:]",
    replace: "    private var epgpwPrefetchTasks: [String: Task<Void, Never>] = [:]\n\n    /// Custom XML url provided by playlists.\n    private var customEPGURLs: [URL] = []")

patchFile("MyApp/EPGRepository.swift",
    search: "func setupWithChannels(_ channels: [Channel]) {",
    replace: "func setupWithChannels(_ channels: [Channel], customEPGURLs: [URL] = []) {\n        self.customEPGURLs = customEPGURLs")

patchFile("MyApp/EPGRepository.swift",
    search: "  if fingerprint == lastChannelFingerprint, setupTask != nil || !canonicalChannels.isEmpty {\n            return\n        }",
    replace: "  if fingerprint == lastChannelFingerprint, setupTask != nil || !canonicalChannels.isEmpty {\n            // Keep it updated if we missed it earlier.\n            return\n        }")

// Wait, I need a safer replacement for setupWithChannels
