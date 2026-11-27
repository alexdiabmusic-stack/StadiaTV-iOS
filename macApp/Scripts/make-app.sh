#!/bin/zsh
# Builds the Swift package and wraps the executable in BannerTV.app (Info.plist, ad-hoc signature).
# Usage: Scripts/make-app.sh [debug|release] [scratch-path] [out.app]     (VERSION=0.2.0 BUILD=2 to stamp the bundle)
set -e
CONFIG="${1:-debug}"
VERSION="${VERSION:-0.2.0}"; BUILD="${BUILD:-2}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH_ARGS=()
[ -n "$2" ] && SCRATCH_ARGS=(--scratch-path "$2")
cd "$HERE"
swift build -c "$CONFIG" "${SCRATCH_ARGS[@]}"
BIN="$(swift build -c "$CONFIG" "${SCRATCH_ARGS[@]}" --show-bin-path)/BannerTVMac"
APP="${3:-$HERE/BannerTV.app}"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/BannerTVMac"
[ -f "$HERE/Resources/AppIcon.icns" ] && cp "$HERE/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
mkdir -p "$APP/Contents/Resources/Fonts" && cp "$HERE"/Resources/Fonts/*.ttf "$APP/Contents/Resources/Fonts/"
cp "$HERE/Resources/wordmark.png" "$APP/Contents/Resources/wordmark.png"
mkdir -p "$APP/Contents/Resources/Integrations" && cp "$HERE"/Resources/Integrations/*.png "$APP/Contents/Resources/Integrations/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>BannerTV</string>
  <key>CFBundleDisplayName</key><string>BannerTV</string>
  <key>CFBundleIdentifier</key><string>tv.banner.mac</string>
  <key>CFBundleExecutable</key><string>BannerTVMac</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.entertainment</string>
  <!-- IPTV and add-on streams are often plain http. -->
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict></plist>
PLIST
# Backend settings come from the local, untracked local.properties (never from source); the app reads them at launch.
PROPS="$HERE/../local.properties"
if [ -f "$PROPS" ]; then
  prop() { grep -E "^$1=" "$PROPS" | head -1 | cut -d= -f2-; }
  /usr/libexec/PlistBuddy -c "Add :BannerSupabaseURL string $(prop NUVIO_SUPABASE_URL)" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :BannerSupabaseAnonKey string $(prop NUVIO_SUPABASE_ANON_KEY)" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :BannerSupabaseFallbackURL string $(prop NUVIO_SUPABASE_FALLBACK_URL)" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :BannerTmdbApiKey string $(prop TMDB_API_KEY)" "$APP/Contents/Info.plist"
fi
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "$APP"
