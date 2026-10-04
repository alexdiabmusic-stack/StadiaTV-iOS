#!/usr/bin/env bash
# Builds Release for the simulator and launches the app with -guideBenchmark <dir>, per
# MatchLinker/PROMPTS.md Prompt 1. Debug timings run ~10x slower and aren't representative, so
# this refuses to run anything but a Release build.
#
#   scripts/benchmark.sh <export-dir>
#
# <export-dir> must hold streams.json, cats.json, xmltv.xml and events.json — produce it with
# MatchLinker/Scripts/export_playlist.sh and export_events.py. Never commit that directory.
set -euo pipefail

DIR="${1:?usage: scripts/benchmark.sh <export-dir>}"
DIR="$(cd "$DIR" && pwd)"
for f in streams.json cats.json xmltv.xml events.json; do
  [ -f "$DIR/$f" ] || { echo "missing $DIR/$f — run MatchLinker/Scripts/export_playlist.sh and export_events.py first" >&2; exit 1; }
done

PROJECT="Stadia TV.xcodeproj"
SCHEME="MyApp"
BUNDLE_ID="com.alexdiab.StadiaTV"
DEVICE_NAME="${BENCHMARK_SIMULATOR:-iPhone 17}"
CONFIGURATION=Release

cd "$(dirname "$0")/.."

UDID="$(xcrun simctl list devices available -j \
  | /usr/bin/python3 -c "import json,sys; d=json.load(sys.stdin)['devices']; print(next((x['udid'] for v in d.values() for x in v if x['name']=='$DEVICE_NAME'), ''))")"
[ -n "$UDID" ] || { echo "no available simulator named '$DEVICE_NAME' (set BENCHMARK_SIMULATOR to another)" >&2; exit 1; }

echo "Building $SCHEME ($CONFIGURATION) for $DEVICE_NAME..."
# GUIDEBENCHMARK compiles the benchmark runner into this one build only; the Release
# configuration itself doesn't define it, so App Store builds never contain the runner.
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIGURATION" \
  -destination "id=$UDID" -derivedDataPath .build/benchmark \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='GUIDEBENCHMARK $(inherited)' build | xcbeautify 2>/dev/null || true

APP_PATH="$(find .build/benchmark/Build/Products/${CONFIGURATION}-iphonesimulator -maxdepth 1 -iname '*.app' | head -1)"
[ -n "$APP_PATH" ] || { echo "build did not produce a .app under .build/benchmark" >&2; exit 1; }

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl install "$UDID" "$APP_PATH"
echo "Running -guideBenchmark $DIR ..."
xcrun simctl launch --console-pty "$UDID" "$BUNDLE_ID" -guideBenchmark "$DIR" -AppleLanguages '(en)'

echo "Wrote $DIR/benchmark.json"
