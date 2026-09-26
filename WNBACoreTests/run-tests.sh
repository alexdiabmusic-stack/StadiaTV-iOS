#!/bin/bash
set -euo pipefail

# Uses the selected Xcode, or DEVELOPER_DIR when testing with a different Xcode.
# This direct runner avoids SwiftPM's nested macro sandbox in Xcode's assistant.
cd "$(dirname "$0")/.."
wnba_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/wnba-tests.XXXXXX")
trap 'rm -rf "$wnba_build_dir"' EXIT
if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    wnba_swiftc="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
    wnba_platform="$DEVELOPER_DIR/Platforms/MacOSX.platform"
    wnba_sdk="$wnba_platform/Developer/SDKs/MacOSX.sdk"
else
    wnba_swiftc=$(xcrun --find swiftc)
    wnba_sdk=$(xcrun --sdk macosx --show-sdk-path)
    wnba_platform=$(xcrun --sdk macosx --show-sdk-platform-path)
fi
wnba_frameworks="$wnba_platform/Developer/Library/Frameworks"
wnba_toolchain=$(dirname "$(dirname "$wnba_swiftc")")
wnba_arch=$(uname -m)
common=(-disable-sandbox -whole-module-optimization -Onone -sdk "$wnba_sdk" -target "$wnba_arch-apple-macosx15.0" -module-cache-path "${WNBA_TEST_MODULE_CACHE:-${TMPDIR:-/tmp}/WNBACoreTestsModuleCache}" -swift-version 6)

"$wnba_swiftc" "${common[@]}" -enable-testing -emit-library -emit-module -module-name WNBACore \
    WNBACoreTests/Sources/WNBACore/*.swift -o "$wnba_build_dir/libWNBACore.dylib" \
    -emit-module-path "$wnba_build_dir/WNBACore.swiftmodule"
"$wnba_swiftc" "${common[@]}" -parse-as-library -module-name WNBACoreTests \
    -I "$wnba_build_dir" -L "$wnba_build_dir" -lWNBACore \
    -F "$wnba_frameworks" -framework Testing \
    -load-plugin-library "$wnba_toolchain/lib/swift/host/plugins/testing/libTestingMacros.dylib" \
    -Xlinker -rpath -Xlinker "$wnba_build_dir" -Xlinker -rpath -Xlinker "$wnba_frameworks" \
    WNBACoreTests/Tests/WNBACoreTests/*.swift WNBACoreTests/DirectRunner.swift -o "$wnba_build_dir/WNBATests"
"$wnba_build_dir/WNBATests" "$@"

if [[ "${WNBA_LIVE_SMOKE:-0}" == "1" ]]; then
    "$wnba_build_dir/WNBATests" --live-smoke
fi
