#!/bin/bash
set -euo pipefail

# Uses the selected Xcode, or DEVELOPER_DIR when testing with a different Xcode.
# This direct runner avoids SwiftPM's nested macro sandbox in Xcode's assistant.
cd "$(dirname "$0")/.."
ll_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/laliga-tests.XXXXXX")
trap 'rm -rf "$ll_build_dir"' EXIT
if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    ll_swiftc="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
    ll_platform="$DEVELOPER_DIR/Platforms/MacOSX.platform"
    ll_sdk="$ll_platform/Developer/SDKs/MacOSX.sdk"
else
    ll_swiftc=$(xcrun --find swiftc)
    ll_sdk=$(xcrun --sdk macosx --show-sdk-path)
    ll_platform=$(xcrun --sdk macosx --show-sdk-platform-path)
fi
ll_frameworks="$ll_platform/Developer/Library/Frameworks"
ll_toolchain=$(dirname "$(dirname "$ll_swiftc")")
ll_arch=$(uname -m)
common=(-disable-sandbox -whole-module-optimization -Onone -sdk "$ll_sdk" -target "$ll_arch-apple-macosx15.0" -module-cache-path "${LALIGA_TEST_MODULE_CACHE:-${TMPDIR:-/tmp}/LaLigaCoreTestsModuleCache}" -swift-version 6)

"$ll_swiftc" "${common[@]}" -enable-testing -emit-library -emit-module -module-name LaLigaCore \
    LaLigaCoreTests/Sources/LaLigaCore/*.swift -o "$ll_build_dir/libLaLigaCore.dylib" \
    -emit-module-path "$ll_build_dir/LaLigaCore.swiftmodule"
"$ll_swiftc" "${common[@]}" -parse-as-library -module-name LaLigaCoreTests \
    -I "$ll_build_dir" -L "$ll_build_dir" -lLaLigaCore \
    -F "$ll_frameworks" -framework Testing \
    -load-plugin-library "$ll_toolchain/lib/swift/host/plugins/testing/libTestingMacros.dylib" \
    -Xlinker -rpath -Xlinker "$ll_build_dir" -Xlinker -rpath -Xlinker "$ll_frameworks" \
    LaLigaCoreTests/Tests/LaLigaCoreTests/*.swift LaLigaCoreTests/DirectRunner.swift -o "$ll_build_dir/LaLigaTests"
"$ll_build_dir/LaLigaTests" "$@"

if [[ "${LALIGA_LIVE_SMOKE:-0}" == "1" ]]; then
    "$ll_build_dir/LaLigaTests" --live-smoke
fi
