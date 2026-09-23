#!/bin/bash
set -euo pipefail

# Uses the selected Xcode, or DEVELOPER_DIR when testing with a different Xcode.
# This direct runner avoids SwiftPM's nested macro sandbox in Xcode's assistant.
cd "$(dirname "$0")/.."
mlb_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/mlb-tests.XXXXXX")
trap 'rm -rf "$mlb_build_dir"' EXIT
if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    mlb_swiftc="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
    mlb_platform="$DEVELOPER_DIR/Platforms/MacOSX.platform"
    mlb_sdk="$mlb_platform/Developer/SDKs/MacOSX.sdk"
else
    mlb_swiftc=$(xcrun --find swiftc)
    mlb_sdk=$(xcrun --sdk macosx --show-sdk-path)
    mlb_platform=$(xcrun --sdk macosx --show-sdk-platform-path)
fi
mlb_frameworks="$mlb_platform/Developer/Library/Frameworks"
mlb_toolchain=$(dirname "$(dirname "$mlb_swiftc")")
mlb_arch=$(uname -m)
common=(-disable-sandbox -whole-module-optimization -Onone -sdk "$mlb_sdk" -target "$mlb_arch-apple-macosx15.0" -module-cache-path "${MLB_TEST_MODULE_CACHE:-${TMPDIR:-/tmp}/MLBCoreTestsModuleCache}" -swift-version 6)

"$mlb_swiftc" "${common[@]}" -enable-testing -emit-library -emit-module -module-name MLBCore \
    MLBCoreTests/Sources/MLBCore/*.swift -o "$mlb_build_dir/libMLBCore.dylib" \
    -emit-module-path "$mlb_build_dir/MLBCore.swiftmodule"
"$mlb_swiftc" "${common[@]}" -parse-as-library -module-name MLBCoreTests \
    -I "$mlb_build_dir" -L "$mlb_build_dir" -lMLBCore \
    -F "$mlb_frameworks" -framework Testing \
    -load-plugin-library "$mlb_toolchain/lib/swift/host/plugins/testing/libTestingMacros.dylib" \
    -Xlinker -rpath -Xlinker "$mlb_build_dir" -Xlinker -rpath -Xlinker "$mlb_frameworks" \
    MLBCoreTests/Tests/MLBCoreTests/*.swift MLBCoreTests/DirectRunner.swift -o "$mlb_build_dir/MLBTests"
"$mlb_build_dir/MLBTests" "$@"

if [[ "${MLB_LIVE_SMOKE:-0}" == "1" ]]; then
    "$mlb_build_dir/MLBTests" --live-smoke
fi
