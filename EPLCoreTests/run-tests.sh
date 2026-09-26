#!/bin/bash
set -euo pipefail

# Uses the selected Xcode, or DEVELOPER_DIR when testing with a different Xcode.
# This direct runner avoids SwiftPM's nested macro sandbox in Xcode's assistant.
cd "$(dirname "$0")/.."
epl_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/epl-tests.XXXXXX")
trap 'rm -rf "$epl_build_dir"' EXIT
if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    epl_swiftc="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
    epl_platform="$DEVELOPER_DIR/Platforms/MacOSX.platform"
    epl_sdk="$epl_platform/Developer/SDKs/MacOSX.sdk"
else
    epl_swiftc=$(xcrun --find swiftc)
    epl_sdk=$(xcrun --sdk macosx --show-sdk-path)
    epl_platform=$(xcrun --sdk macosx --show-sdk-platform-path)
fi
epl_frameworks="$epl_platform/Developer/Library/Frameworks"
epl_toolchain=$(dirname "$(dirname "$epl_swiftc")")
epl_arch=$(uname -m)
common=(-disable-sandbox -whole-module-optimization -Onone -sdk "$epl_sdk" -target "$epl_arch-apple-macosx15.0" -module-cache-path "${EPL_TEST_MODULE_CACHE:-${TMPDIR:-/tmp}/EPLCoreTestsModuleCache}" -swift-version 6)

"$epl_swiftc" "${common[@]}" -enable-testing -emit-library -emit-module -module-name EPLCore \
    EPLCoreTests/Sources/EPLCore/*.swift -o "$epl_build_dir/libEPLCore.dylib" \
    -emit-module-path "$epl_build_dir/EPLCore.swiftmodule"
"$epl_swiftc" "${common[@]}" -parse-as-library -module-name EPLCoreTests \
    -I "$epl_build_dir" -L "$epl_build_dir" -lEPLCore \
    -F "$epl_frameworks" -framework Testing \
    -load-plugin-library "$epl_toolchain/lib/swift/host/plugins/testing/libTestingMacros.dylib" \
    -Xlinker -rpath -Xlinker "$epl_build_dir" -Xlinker -rpath -Xlinker "$epl_frameworks" \
    EPLCoreTests/Tests/EPLCoreTests/*.swift EPLCoreTests/DirectRunner.swift -o "$epl_build_dir/EPLTests"
"$epl_build_dir/EPLTests" "$@"

if [[ "${EPL_LIVE_SMOKE:-0}" == "1" ]]; then
    "$epl_build_dir/EPLTests" --live-smoke
fi
