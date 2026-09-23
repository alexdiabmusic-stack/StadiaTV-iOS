#!/bin/bash
set -euo pipefail

# Uses the selected Xcode, or DEVELOPER_DIR when testing with a different Xcode.
# This direct runner avoids SwiftPM's nested macro sandbox in Xcode's assistant.
cd "$(dirname "$0")/.."
nfl_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/nfl-tests.XXXXXX")
trap 'rm -rf "$nfl_build_dir"' EXIT
if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    nfl_swiftc="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
    nfl_platform="$DEVELOPER_DIR/Platforms/MacOSX.platform"
    nfl_sdk="$nfl_platform/Developer/SDKs/MacOSX.sdk"
else
    nfl_swiftc=$(xcrun --find swiftc)
    nfl_sdk=$(xcrun --sdk macosx --show-sdk-path)
    nfl_platform=$(xcrun --sdk macosx --show-sdk-platform-path)
fi
nfl_frameworks="$nfl_platform/Developer/Library/Frameworks"
nfl_toolchain=$(dirname "$(dirname "$nfl_swiftc")")
nfl_arch=$(uname -m)
common=(-disable-sandbox -whole-module-optimization -Onone -sdk "$nfl_sdk" -target "$nfl_arch-apple-macosx15.0" -module-cache-path "${NFL_TEST_MODULE_CACHE:-${TMPDIR:-/tmp}/NFLCoreTestsModuleCache}" -swift-version 6)

"$nfl_swiftc" "${common[@]}" -enable-testing -emit-library -emit-module -module-name NFLCore \
    NFLCoreTests/Sources/NFLCore/*.swift -o "$nfl_build_dir/libNFLCore.dylib" \
    -emit-module-path "$nfl_build_dir/NFLCore.swiftmodule"
"$nfl_swiftc" "${common[@]}" -parse-as-library -module-name NFLCoreTests \
    -I "$nfl_build_dir" -L "$nfl_build_dir" -lNFLCore \
    -F "$nfl_frameworks" -framework Testing \
    -load-plugin-library "$nfl_toolchain/lib/swift/host/plugins/testing/libTestingMacros.dylib" \
    -Xlinker -rpath -Xlinker "$nfl_build_dir" -Xlinker -rpath -Xlinker "$nfl_frameworks" \
    NFLCoreTests/Tests/NFLCoreTests/*.swift NFLCoreTests/DirectRunner.swift -o "$nfl_build_dir/NFLTests"
"$nfl_build_dir/NFLTests" "$@"
