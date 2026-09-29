import Foundation

func patchFile(_ path: String, search: String, replace: String) {
    let content = try! String(contentsOfFile: path)
    let newContent = content.replacingOccurrences(of: search, with: replace)
    try! newContent.write(toFile: path, atomically: true, encoding: .utf8)
}

patchFile("MyApp/LiveChannelRepository.swift",
    search: "        return liveChannels.map { $0.asChannel(playlistName: playlist.name) }\n    }",
    replace: "        return (liveChannels.map { $0.asChannel(playlistName: playlist.name) }, epgURL)\n    }")

