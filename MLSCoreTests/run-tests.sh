#!/bin/bash
set -euo pipefail

# Uses the selected Xcode, or DEVELOPER_DIR when testing with a different Xcode.
# This direct runner avoids SwiftPM's nested macro sandbox in Xcode's assistant.
cd "$(dirname "$0")/.."
mls_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/mls-tests.XXXXXX")
trap 'rm -rf "$mls_build_dir"' EXIT
if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    mls_swiftc="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
    mls_platform="$DEVELOPER_DIR/Platforms/MacOSX.platform"
    mls_sdk="$mls_platform/Developer/SDKs/MacOSX.sdk"
else
    mls_swiftc=$(xcrun --find swiftc)
    mls_sdk=$(xcrun --sdk macosx --show-sdk-path)
    mls_platform=$(xcrun --sdk macosx --show-sdk-platform-path)
fi
mls_frameworks="$mls_platform/Developer/Library/Frameworks"
mls_toolchain=$(dirname "$(dirname "$mls_swiftc")")
mls_arch=$(uname -m)
common=(-disable-sandbox -whole-module-optimization -Onone -sdk "$mls_sdk" -target "$mls_arch-apple-macosx15.0" -module-cache-path "${MLS_TEST_MODULE_CACHE:-${TMPDIR:-/tmp}/MLSCoreTestsModuleCache}" -swift-version 6)

"$mls_swiftc" "${common[@]}" -enable-testing -emit-library -emit-module -module-name MLSCore \
    MLSCoreTests/Sources/MLSCore/*.swift -o "$mls_build_dir/libMLSCore.dylib" \
    -emit-module-path "$mls_build_dir/MLSCore.swiftmodule"
"$mls_swiftc" "${common[@]}" -parse-as-library -module-name MLSCoreTests \
    -I "$mls_build_dir" -L "$mls_build_dir" -lMLSCore \
    -F "$mls_frameworks" -framework Testing \
    -load-plugin-library "$mls_toolchain/lib/swift/host/plugins/testing/libTestingMacros.dylib" \
    -Xlinker -rpath -Xlinker "$mls_build_dir" -Xlinker -rpath -Xlinker "$mls_frameworks" \
    MLSCoreTests/Tests/MLSCoreTests/*.swift MLSCoreTests/DirectRunner.swift -o "$mls_build_dir/MLSTests"
"$mls_build_dir/MLSTests" "$@"

if [[ "${MLS_LIVE_SMOKE:-0}" == "1" ]]; then
    "$mls_build_dir/MLSTests" --live-smoke
fi
