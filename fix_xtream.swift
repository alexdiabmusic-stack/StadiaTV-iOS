import Foundation

func patchFile(_ path: String, search: String, replace: String) {
    let content = try! String(contentsOfFile: path)
    let newContent = content.replacingOccurrences(of: search, with: replace)
    try! newContent.write(toFile: path, atomically: true, encoding: .utf8)
}

patchFile("MyApp/XtreamProviderAdapter.swift",
    search: "return await Task.detached(priority: .userInitiated) {\n            streams.map { stream in",
    replace: "let channels = await Task.detached(priority: .userInitiated) {\n            streams.map { stream in")

patchFile("MyApp/XtreamProviderAdapter.swift",
    search: "archiveDays: stream.tv_archive_duration ?? 0\n                )\n            }\n        }.value\n    }",
    replace: "archiveDays: stream.tv_archive_duration ?? 0\n                )\n            }\n        }.value\n        return (epgURL, channels)\n    }")

