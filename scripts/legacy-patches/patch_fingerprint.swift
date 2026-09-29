import Foundation

let path = "MyApp/EPGRepository.swift"
var content = try! String(contentsOfFile: path, encoding: .utf8)
let searchStr = "let fingerprint = Self.channelFingerprint(channels)"
let replaceStr = "let fingerprint = Self.channelFingerprint(channels) + customEPGURLs.map { $0.absoluteString }.joined()"
content = content.replacingOccurrences(of: searchStr, with: replaceStr)

let searchStr2 = "    nonisolated private static func channelFingerprint(_ channels: [Channel]) -> String {"
let replaceStr2 = "    nonisolated private static func channelFingerprint(_ channels: [Channel]) -> String {"
// actually no need, replacing the caller is enough

try! content.write(toFile: path, atomically: true, encoding: .utf8)
