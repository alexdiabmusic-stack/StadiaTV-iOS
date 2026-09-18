import Foundation

func patchFile(_ path: String, search: String, replace: String) {
    let content = try! String(contentsOfFile: path)
    let newContent = content.replacingOccurrences(of: search, with: replace)
    try! newContent.write(toFile: path, atomically: true, encoding: .utf8)
}

patchFile("MyApp/XtreamProviderAdapter.swift",
    search: "func loadChannels() async throws -> [AdapterChannel] {",
    replace: "func loadChannels() async throws -> (epgURL: String?, channels: [AdapterChannel]) {")

patchFile("MyApp/XtreamProviderAdapter.swift",
    search: "return await Task.detached(priority: .userInitiated)",
    replace: "var epgComps = base\n        epgComps.path = \"/xmltv.php\"\n        epgComps.queryItems = [\n            URLQueryItem(name: \"username\", value: user),\n            URLQueryItem(name: \"password\", value: pass)\n        ]\n        let epgURL = epgComps.url?.absoluteString\n\n        return await Task.detached(priority: .userInitiated)")

patchFile("MyApp/XtreamProviderAdapter.swift",
    search: "return parsed",
    replace: "return (epgURL, parsed)")

