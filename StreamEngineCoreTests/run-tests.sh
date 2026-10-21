#!/bin/bash
set -euo pipefail

# Uses the selected Xcode, or DEVELOPER_DIR when testing with a different Xcode.
# This direct runner avoids SwiftPM's nested macro sandbox in Xcode's assistant. The end-to-end
# tests bind loopback sockets, which the direct runner may do outside any sandbox.
cd "$(dirname "$0")/.."
engine_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/stream-engine-tests.XXXXXX")
trap 'rm -rf "$engine_build_dir"' EXIT
if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    engine_swiftc="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
    engine_platform="$DEVELOPER_DIR/Platforms/MacOSX.platform"
    engine_sdk="$engine_platform/Developer/SDKs/MacOSX.sdk"
else
    engine_swiftc=$(xcrun --find swiftc)
    engine_sdk=$(xcrun --sdk macosx --show-sdk-path)
    engine_platform=$(xcrun --sdk macosx --show-sdk-platform-path)
fi
engine_frameworks="$engine_platform/Developer/Library/Frameworks"
engine_toolchain=$(dirname "$(dirname "$engine_swiftc")")
engine_arch=$(uname -m)
common=(-disable-sandbox -whole-module-optimization -Onone -sdk "$engine_sdk" -target "$engine_arch-apple-macosx15.0" -module-cache-path "${STREAM_ENGINE_TEST_MODULE_CACHE:-${TMPDIR:-/tmp}/StreamEngineCoreTestsModuleCache}" -swift-version 6)

"$engine_swiftc" "${common[@]}" -enable-testing -emit-library -emit-module -module-name StreamEngineCore \
    StreamEngineCoreTests/Sources/StreamEngineCore/*.swift -o "$engine_build_dir/libStreamEngineCore.dylib" \
    -emit-module-path "$engine_build_dir/StreamEngineCore.swiftmodule"
"$engine_swiftc" "${common[@]}" -parse-as-library -module-name StreamEngineCoreTests \
    -I "$engine_build_dir" -L "$engine_build_dir" -lStreamEngineCore \
    -F "$engine_frameworks" -framework Testing \
    -load-plugin-library "$engine_toolchain/lib/swift/host/plugins/testing/libTestingMacros.dylib" \
    -Xlinker -rpath -Xlinker "$engine_build_dir" -Xlinker -rpath -Xlinker "$engine_frameworks" \
    StreamEngineCoreTests/Tests/StreamEngineCoreTests/*.swift StreamEngineCoreTests/DirectRunner.swift -o "$engine_build_dir/StreamEngineTests"
"$engine_build_dir/StreamEngineTests" "$@"
