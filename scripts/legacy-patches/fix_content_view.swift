import Foundation

var content = try! String(contentsOfFile: "MyApp/ContentView.swift", encoding: .utf8)
content = content.replacingOccurrences(of: """
.task { epgRepository.setupWithChannels(playlistStore.allChannels) }
""", with: """
.task(id: playlistStore.playlists) { 
            epgRepository.setupWithChannels(
                playlistStore.allChannels,
                customEPGURLs: playlistStore.playlists.compactMap(\\.epgURL).compactMap(URL.init(string:))
            ) 
        }
""")

content = content.replacingOccurrences(of: """
epgRepository.setupWithChannels(playlistStore.allChannels)
""", with: """
epgRepository.setupWithChannels(
                playlistStore.allChannels,
                customEPGURLs: playlistStore.playlists.compactMap(\\.epgURL).compactMap(URL.init(string:))
            )
""")

try! content.write(toFile: "MyApp/ContentView.swift", atomically: true, encoding: .utf8)
