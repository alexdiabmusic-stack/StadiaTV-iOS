import Foundation

let path = "MyApp/EPGRepository.swift"
var content = try! String(contentsOfFile: path, encoding: .utf8)
let searchStr = "        for epgCh in epgChannels {"
let replaceStr = """
        // Also build a lookup for unresolved streams using their tvg-id!
        for stream in unresolvedStreams {
            guard let epgId = stream.tvgId?.lowercased(), !epgId.isEmpty else { continue }
            if aliasToCanon[epgId] == nil {
                aliasToCanon[epgId] = stream.id
            }
        }

        for epgCh in epgChannels {
"""
content = content.replacingOccurrences(of: searchStr, with: replaceStr)
try! content.write(toFile: path, atomically: true, encoding: .utf8)
