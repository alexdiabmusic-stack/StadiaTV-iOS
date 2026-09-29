import Foundation

var content = try! String(contentsOfFile: "MyApp/EPGRepository.swift", encoding: .utf8)
content = content.replacingOccurrences(of: """
    private var customEPGURLs: [URL] = []
    private var customEPGURLs: [URL] = []
""", with: "    private var customEPGURLs: [URL] = []")

try! content.write(toFile: "MyApp/EPGRepository.swift", atomically: true, encoding: .utf8)
