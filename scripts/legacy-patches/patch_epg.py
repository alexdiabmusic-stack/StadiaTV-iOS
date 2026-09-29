import re

with open('MyApp/EPGRepository.swift', 'r') as f:
    content = f.read()

# 1. Add custom EPG property
content = re.sub(
    r'private var epgpwPrefetchTasks: \[String: Task<Void, Never>\] = \[:\]',
    r'private var epgpwPrefetchTasks: [String: Task<Void, Never>] = [:]\n    private var customEPGURLs: [URL] = []',
    content
)

# 2. Add param to setupWithChannels
content = re.sub(
    r'func setupWithChannels\(_ channels: \[Channel\]\) \{',
    r'func setupWithChannels(_ channels: [Channel], customEPGURLs: [URL] = []) {\n        self.customEPGURLs = customEPGURLs',
    content
)

# 3. Add custom EPG urls to forces refresh sources
refresh_search = r'let sources = EPGSourceRegistry\.sources\(for: activeCategoryIds\)'
refresh_replace = r'''var sources = EPGSourceRegistry.sources(for: activeCategoryIds)
        for (i, url) in customEPGURLs.enumerated() {
            let src = EPGSource(id: "custom-\(i)", displayName: "Playlist EPG", url: url, categoryIds: [], priority: sources.count + i, cacheTTL: 6 * 3600, isEnabled: true)
            sources.append(src)
        }'''
content = content.replace(refresh_search, refresh_replace)

# 4. In matchEPGChannels, map unresolvedStreams
match_epg_search = r'for alias in curatedCh.aliases {'
match_epg_replace = r'''for alias in curatedCh.aliases {'''
# wait, better to append at the end of matchEPGChannels loop
match_epg_end_search = r'''        }

        // Apply map to the mutating list
'''
match_epg_end_replace = r'''        }

        for stream in unresolvedStreams {
            guard let epgId = stream.tvgId?.lowercased(), !epgId.isEmpty else { continue }
            if aliasToCanon[epgId] == nil {
                aliasToCanon[epgId] = stream.id
            }
        }

        // Apply map to the mutating list
'''

content = content.replace(match_epg_end_search, match_epg_end_replace)

# 5. In rebuildChannelToCanonicalMap
rebuild_search = r'''
        for canonical in canonicalChannels {
            for stream in canonical.allStreams {
                map[stream.providerChannelId] = canonical.id
            }
        }
'''
rebuild_replace = r'''
        for canonical in canonicalChannels {
            for stream in canonical.allStreams {
                map[stream.providerChannelId] = canonical.id
            }
        }
        for stream in unresolvedStreams {
            if stream.tvgId?.isEmpty == false {
                map[stream.providerChannelId] = stream.id
            }
        }
'''
content = content.replace(rebuild_search, rebuild_replace)


with open('MyApp/EPGRepository.swift', 'w') as f:
    f.write(content)
