# BannerTV for macOS

A native SwiftUI/AppKit Mac app on the shared Kotlin core. Plan and reasoning: `../../research/BannerTV-macOS-Architecture.md`; slice status: `../../research/MAC-APP-SLICES.md`.

## What is in it
- **Home**: hero, Continue Watching, Top 10 Today, Recommended For You, personal rows, Explore Collections, the add-ons' catalogs. Row order follows the profile (the arrangement made on the phone or TV applies, and can be changed in Settings).
- **Details**: artwork, cast, seasons and episodes, My List, watched marks, Resume.
- **Sources and playback**: every installed stream add-on answers as it can; mpv plays through Metal with VideoToolbox. External subtitles from add-ons, audio/subtitle tracks, speed, preferred languages, next episode with automatic source choice.
- **Explore**: collections by category with TMDB artwork and pages.
- **Search**: across add-on catalogs, with recent searches.
- **Library**: My List per profile.
- **Live TV and Guide**: M3U playlists and Xtream logins (password in the Keychain), XMLTV guide, favourites, recents.
- **Profiles and account**: email sign-in, "Who's watching?" with PINs, or use without an account (local only).
- **Integrations** (Settings): **Serializd** (email and password, kept in the Keychain) and **Letterboxd** (you sign in on Letterboxd's own page; only the session is kept). Both log what you finish watching (episodes to Serializd, films to Letterboxd), can import your history and add your watchlist to My List, and show what was sent, held or stopped. Imported history keeps its real dates and is never sent back. Ratings and reviews can't be given from the Mac yet, so the "Sync ratings" switches only matter for ratings made on your other devices.
- **Look**: follows the iPhone app's design: black surfaces, JetBrains Sans, a full-bleed hero with title art, white Play pill, rounded poster rows, outlined Top 10 numerals, collection cards, a floating navigation pill (Home, Live TV, Search, Sports, Library) with the profile button for Settings. Tokens are in `Sources/BannerTVMac/Theme.swift`.
- **Sports**: My Sports, All Events by day, Leagues with tables and teams, and a game page that lists the channels (from your IPTV guide) and add-on streams showing it. Scores and schedules come from the same feeds as the phone app. News, game reminders and live-score alerts are not on the Mac.
- **Not in this build**: torrent sources, multiview, notarization (see Distribution).

## Layout
- `Sources/BannerPlayer`: mpv player in an `NSView` on a Metal layer.
- `Sources/BannerTVMac`: the app. `AccountModel`, `HomeModel`, `UserDataModel`, `LiveTvModel`, `ContentModels` are the only places that touch Kotlin types besides `CoreBridge.swift`.
- `../bannerCore`: the shared Kotlin core, linked as an XCFramework. Mac-specific Kotlin lives in `bannerCore/src/macosMain/.../mac` (`MacBridge` is the Swift-facing surface).

## Build and run
```bash
# 1. Build the Kotlin core for the Mac and copy it next to the package (from nuvio-enhanced/)
./gradlew -Pnuvio.android.distribution=full :bannerCore:assembleBannerCoreDebugXCFramework
macApp/Scripts/sync-core.sh
# 2. Build and wrap the app (writes the backend settings from ../local.properties into Info.plist)
macApp/Scripts/make-app.sh release
open macApp/BannerTV.app
# 3. A disk image for sharing (VERSION=0.2.0 BUILD=2 stamps the bundle; use the release XCFramework, assembleBannerCoreReleaseXCFramework, for a build to hand out)
macApp/Scripts/make-dmg.sh macApp/BannerTV.app BannerTV.dmg
```
Apple Silicon only, macOS 14 or later. `Scripts/make-icon.py` rebuilds the icon from the iPhone app's artwork.

## Automated checks (debug flags)
`--anonymous`, `--section <name>`, `--open <type>:<id>`, `--open-collection <id>`, `--search <text>`, `--press-play`, `--auto-source`, `--debug-player`, `--selftest-addon <urls>`, `--snapshot <png> [--snapshot-delay <s>]` (the app renders its own window to a PNG and quits), `--dev` (shows Player Test).

## Distribution
The app links the GPL variant of MPVKit (the only one with a macOS slice), so it is GPL-3.0. **Running the DMG on another Mac:** the app is signed ad hoc, so macOS blocks a copy that arrived by AirDrop or download the first time. Drag it to Applications, then either right-click it and choose Open (twice, the first attempt is refused), or run `xattr -dr com.apple.quarantine /Applications/BannerTV.app`. Apple Silicon Macs on macOS 14 or later only. Each Mac keeps its own sign-ins (BannerTV account, Serializd, Letterboxd). A notarized DMG needs a Developer ID certificate and `xcrun notarytool` credentials, which are the owner's to supply; `make-app.sh` signs ad-hoc. The Mac App Store needs a legal opinion on GPL first.
