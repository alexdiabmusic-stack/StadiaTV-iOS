#!/bin/bash
set -euo pipefail

# Uses the selected Xcode, or DEVELOPER_DIR when testing with a different Xcode.
# This direct runner avoids SwiftPM's nested macro sandbox in Xcode's assistant.
cd "$(dirname "$0")/.."
cfl_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/cfl-tests.XXXXXX")
trap 'rm -rf "$cfl_build_dir"' EXIT
if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    cfl_swiftc="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
    cfl_platform="$DEVELOPER_DIR/Platforms/MacOSX.platform"
    cfl_sdk="$cfl_platform/Developer/SDKs/MacOSX.sdk"
else
    cfl_swiftc=$(xcrun --find swiftc)
    cfl_sdk=$(xcrun --sdk macosx --show-sdk-path)
    cfl_platform=$(xcrun --sdk macosx --show-sdk-platform-path)
fi
cfl_frameworks="$cfl_platform/Developer/Library/Frameworks"
cfl_toolchain=$(dirname "$(dirname "$cfl_swiftc")")
cfl_arch=$(uname -m)
common=(-disable-sandbox -whole-module-optimization -Onone -sdk "$cfl_sdk" -target "$cfl_arch-apple-macosx15.0" -module-cache-path "${CFL_TEST_MODULE_CACHE:-${TMPDIR:-/tmp}/CFLCoreTestsModuleCache}" -swift-version 6)

"$cfl_swiftc" "${common[@]}" -enable-testing -emit-library -emit-module -module-name CFLCore \
    CFLCoreTests/Sources/CFLCore/*.swift -o "$cfl_build_dir/libCFLCore.dylib" \
    -emit-module-path "$cfl_build_dir/CFLCore.swiftmodule"
"$cfl_swiftc" "${common[@]}" -parse-as-library -module-name CFLCoreTests \
    -I "$cfl_build_dir" -L "$cfl_build_dir" -lCFLCore \
    -F "$cfl_frameworks" -framework Testing \
    -load-plugin-library "$cfl_toolchain/lib/swift/host/plugins/testing/libTestingMacros.dylib" \
    -Xlinker -rpath -Xlinker "$cfl_build_dir" -Xlinker -rpath -Xlinker "$cfl_frameworks" \
    CFLCoreTests/Tests/CFLCoreTests/*.swift CFLCoreTests/DirectRunner.swift -o "$cfl_build_dir/CFLTests"
"$cfl_build_dir/CFLTests" "$@"
