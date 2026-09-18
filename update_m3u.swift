import Foundation

func patchFile(_ path: String, search: String, replace: String) {
    let content = try! String(contentsOfFile: path)
    let newContent = content.replacingOccurrences(of: search, with: replace)
    try! newContent.write(toFile: path, atomically: true, encoding: .utf8)
}

patchFile("MyApp/M3UProviderAdapter.swift",
    search: "func loadGroups() async throws -> [AdapterGroup] {\n        let channels = try await loadChannels()",
    replace: "func loadGroups() async throws -> [AdapterGroup] {\n        let (_, channels) = try await loadChannels()")

patchFile("MyApp/M3UProviderAdapter.swift",
    search: "func loadChannels() async throws -> [AdapterChannel] {\n        guard let urlString = provider.m3uURL",
    replace: "func loadChannels() async throws -> (epgURL: String?, channels: [AdapterChannel]) {\n        guard let urlString = provider.m3uURL")

patchFile("MyApp/M3UProviderAdapter.swift",
    search: "static func parseM3U(_ text: String) -> [AdapterChannel] {",
    replace: "static func parseM3U(_ text: String) -> (epgURL: String?, channels: [AdapterChannel]) {")

patchFile("MyApp/M3UProviderAdapter.swift",
    search: "var channels: [AdapterChannel] = []",
    replace: "var channels: [AdapterChannel] = []\n        var epgURL: String?")

patchFile("MyApp/M3UProviderAdapter.swift",
    search: "if line.hasPrefix(\"#EXTINF\") {",
    replace: "if line.hasPrefix(\"#EXTM3U\") {\n                epgURL = attribute(\"x-tvg-url\", in: line)\n            } else if line.hasPrefix(\"#EXTINF\") {")

patchFile("MyApp/M3UProviderAdapter.swift",
    search: "return channels\n    }",
    replace: "return (epgURL, channels)\n    }")

