import Foundation

func patchFile(_ path: String, search: String, replace: String) {
    let content = try! String(contentsOfFile: path)
    let newContent = content.replacingOccurrences(of: search, with: replace)
    try! newContent.write(toFile: path, atomically: true, encoding: .utf8)
}

// 1. Models.swift
patchFile("MyApp/Models.swift",
    search: "var m3uURL: String?",
    replace: "var m3uURL: String?\n    var epgURL: String?")

patchFile("MyApp/Models.swift",
    search: "m3uURL: String? = nil, host: String? = nil",
    replace: "m3uURL: String? = nil, epgURL: String? = nil, host: String? = nil")

patchFile("MyApp/Models.swift",
    search: "self.m3uURL = m3uURL",
    replace: "self.m3uURL = m3uURL\n        self.epgURL = epgURL")

patchFile("MyApp/Models.swift",
    search: "case id, name, kind, m3uURL, host, credentialID, username, password",
    replace: "case id, name, kind, m3uURL, epgURL, host, credentialID, username, password")

patchFile("MyApp/Models.swift",
    search: "m3uURL = try container.decodeIfPresent(String.self, forKey: .m3uURL)",
    replace: "m3uURL = try container.decodeIfPresent(String.self, forKey: .m3uURL)\n        epgURL = try container.decodeIfPresent(String.self, forKey: .epgURL)")

patchFile("MyApp/Models.swift",
    search: "try container.encodeIfPresent(m3uURL, forKey: .m3uURL)",
    replace: "try container.encodeIfPresent(m3uURL, forKey: .m3uURL)\n        try container.encodeIfPresent(epgURL, forKey: .epgURL)")

patchFile("MyApp/Models.swift",
    search: "Playlist(id: id, name: name, kind: kind, m3uURL: m3uURL, host: host, credentialID: credentialID)",
    replace: "Playlist(id: id, name: name, kind: kind, m3uURL: m3uURL, epgURL: epgURL, host: host, credentialID: credentialID)")

// 2. LiveModels.swift
patchFile("MyApp/LiveModels.swift",
    search: "var m3uURL: String?",
    replace: "var m3uURL: String?\n    var epgURL: String?")

patchFile("MyApp/LiveModels.swift",
    search: "self.m3uURL = playlist.m3uURL",
    replace: "self.m3uURL = playlist.m3uURL\n        self.epgURL = playlist.epgURL")

