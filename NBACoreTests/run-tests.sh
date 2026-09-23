#!/bin/bash
set -euo pipefail

# Uses the selected Xcode, or DEVELOPER_DIR when testing with a different Xcode.
# This direct runner avoids SwiftPM's nested macro sandbox in Xcode's assistant.
cd "$(dirname "$0")/.."
nba_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/nba-tests.XXXXXX")
trap 'rm -rf "$nba_build_dir"' EXIT
if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    nba_swiftc="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
    nba_platform="$DEVELOPER_DIR/Platforms/MacOSX.platform"
    nba_sdk="$nba_platform/Developer/SDKs/MacOSX.sdk"
else
    nba_swiftc=$(xcrun --find swiftc)
    nba_sdk=$(xcrun --sdk macosx --show-sdk-path)
    nba_platform=$(xcrun --sdk macosx --show-sdk-platform-path)
fi
nba_frameworks="$nba_platform/Developer/Library/Frameworks"
nba_toolchain=$(dirname "$(dirname "$nba_swiftc")")
nba_arch=$(uname -m)
common=(-disable-sandbox -whole-module-optimization -Onone -sdk "$nba_sdk" -target "$nba_arch-apple-macosx15.0" -module-cache-path "${NBA_TEST_MODULE_CACHE:-${TMPDIR:-/tmp}/NBACoreTestsModuleCache}" -swift-version 6)

"$nba_swiftc" "${common[@]}" -enable-testing -emit-library -emit-module -module-name NBACore \
    NBACoreTests/Sources/NBACore/*.swift -o "$nba_build_dir/libNBACore.dylib" \
    -emit-module-path "$nba_build_dir/NBACore.swiftmodule"
"$nba_swiftc" "${common[@]}" -parse-as-library -module-name NBACoreTests \
    -I "$nba_build_dir" -L "$nba_build_dir" -lNBACore \
    -F "$nba_frameworks" -framework Testing \
    -load-plugin-library "$nba_toolchain/lib/swift/host/plugins/testing/libTestingMacros.dylib" \
    -Xlinker -rpath -Xlinker "$nba_build_dir" -Xlinker -rpath -Xlinker "$nba_frameworks" \
    NBACoreTests/Tests/NBACoreTests/*.swift NBACoreTests/DirectRunner.swift -o "$nba_build_dir/NBATests"
"$nba_build_dir/NBATests" "$@"

if [[ "${NBA_LIVE_SMOKE:-0}" == "1" ]]; then
    "$nba_build_dir/NBATests" --live-smoke
fi
