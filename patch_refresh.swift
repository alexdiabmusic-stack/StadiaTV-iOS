import Foundation

let path = "MyApp/EPGRepository.swift"
var content = try! String(contentsOfFile: path, encoding: .utf8)
let searchStr = """
    func refreshIfNeeded() async {
        guard EPGPWSourcePolicy.epgShareFallbackEnabled else { return }
        let staleness: TimeInterval = 6 * 3600
        // Skip download if the cache is fresh AND the cache file exists on disk.
        // lastUpdated is loaded synchronously from UserDefaults at init time so this
        // check is valid even before the async disk-load of programmeIndex completes.
        if let last = lastUpdated, Date().timeIntervalSince(last) < staleness,
           FileManager.default.fileExists(atPath: programmeCacheURL.path) { return }
        await forceRefresh()
    }
"""

let replaceStr = """
    func refreshIfNeeded() async {
        guard EPGPWSourcePolicy.epgShareFallbackEnabled else { return }
        
        var missingCustomSource = false
        for (i, _) in customEPGURLs.enumerated() {
            let cacheFile = cacheDir.appendingPathComponent("custom-\\(i).xml")
            if !FileManager.default.fileExists(atPath: cacheFile.path) {
                missingCustomSource = true
                break
            }
        }
        
        let staleness: TimeInterval = 6 * 3600
        if !missingCustomSource, let last = lastUpdated, Date().timeIntervalSince(last) < staleness,
           FileManager.default.fileExists(atPath: programmeCacheURL.path) { return }
        await forceRefresh()
    }
"""
content = content.replacingOccurrences(of: searchStr, with: replaceStr)

// Also ensure customEPGURLs array changes trigger a refresh
// In setupWithChannels, lastChannelFingerprint handles channels but what about customEPGURLs?
// We need to fingerprint customEPGURLs as well.

try! content.write(toFile: path, atomically: true, encoding: .utf8)
