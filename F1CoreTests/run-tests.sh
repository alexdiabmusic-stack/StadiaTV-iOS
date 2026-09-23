#!/bin/bash
set -euo pipefail

# Uses the selected Xcode, or DEVELOPER_DIR when testing with a different Xcode.
# This direct runner avoids SwiftPM's nested macro sandbox in Xcode's assistant.
cd "$(dirname "$0")/.."
f1_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/f1-tests.XXXXXX")
trap 'rm -rf "$f1_build_dir"' EXIT
if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    f1_swiftc="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
    f1_platform="$DEVELOPER_DIR/Platforms/MacOSX.platform"
    f1_sdk="$f1_platform/Developer/SDKs/MacOSX.sdk"
else
    f1_swiftc=$(xcrun --find swiftc)
    f1_sdk=$(xcrun --sdk macosx --show-sdk-path)
    f1_platform=$(xcrun --sdk macosx --show-sdk-platform-path)
fi
f1_frameworks="$f1_platform/Developer/Library/Frameworks"
f1_toolchain=$(dirname "$(dirname "$f1_swiftc")")
f1_arch=$(uname -m)
common=(-disable-sandbox -whole-module-optimization -Onone -sdk "$f1_sdk" -target "$f1_arch-apple-macosx15.0" -module-cache-path "${F1_TEST_MODULE_CACHE:-${TMPDIR:-/tmp}/F1CoreTestsModuleCache}" -swift-version 6)

"$f1_swiftc" "${common[@]}" -lz -enable-testing -emit-library -emit-module -module-name F1Core \
    F1CoreTests/Sources/F1Core/*.swift -o "$f1_build_dir/libF1Core.dylib" \
    -emit-module-path "$f1_build_dir/F1Core.swiftmodule"
"$f1_swiftc" "${common[@]}" -parse-as-library -module-name F1CoreTests \
    -I "$f1_build_dir" -L "$f1_build_dir" -lF1Core \
    -F "$f1_frameworks" -framework Testing \
    -load-plugin-library "$f1_toolchain/lib/swift/host/plugins/testing/libTestingMacros.dylib" \
    -Xlinker -rpath -Xlinker "$f1_build_dir" -Xlinker -rpath -Xlinker "$f1_frameworks" \
    F1CoreTests/Tests/F1CoreTests/*.swift F1CoreTests/DirectRunner.swift -o "$f1_build_dir/F1Tests"
"$f1_build_dir/F1Tests" "$@"
