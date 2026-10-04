#!/bin/sh
# Release-readiness report for the build configuration. Run by ci_scripts/ci_pre_xcodebuild.sh
# on archive builds; also safe to run by hand: scripts/check-release-config.sh
#
# Prints one line per finding. Exits non-zero only when STRICT_RELEASE_CONFIG=1 is set in the
# environment (add it to the Xcode Cloud archive workflow once the app ships with its paywall).
set -eu

ROOT="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "$0")/.." && pwd)}"
PROJECT="$ROOT/Stadia TV.xcodeproj/project.pbxproj"
problems=0

# The value of an xcconfig setting; Secrets.xcconfig is included last, so it wins.
setting() {
    for file in "$ROOT/Config/App.xcconfig" "$ROOT/Config/Secrets.xcconfig"; do
        [ -f "$file" ] || continue
        sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\([A-Za-z0-9_.-]*\).*/\1/p" "$file"
    done | tail -n 1
}

if [ "$(setting BANNER_UNLOCK_ALL_FEATURES | tr '[:lower:]' '[:upper:]')" = "YES" ]; then
    echo "release-config: BANNER_UNLOCK_ALL_FEATURES = YES — every premium feature is unlocked and StoreKit is bypassed."
    problems=$((problems + 1))
fi

if grep -q 'GUIDEBENCHMARK' "$PROJECT"; then
    # Debug may define it; the Release configuration must not.
    if awk '/Release configuration for PBXNativeTarget "MyApp" \*\/ = \{/,/name = Release;/' "$PROJECT" | grep -q GUIDEBENCHMARK; then
        echo "release-config: the MyApp Release configuration defines GUIDEBENCHMARK, which ships the benchmark runner."
        problems=$((problems + 1))
    fi
fi

if [ "$problems" -eq 0 ]; then
    echo "release-config: OK"
elif [ "${STRICT_RELEASE_CONFIG:-0}" = "1" ]; then
    echo "release-config: $problems problem(s); failing because STRICT_RELEASE_CONFIG=1." >&2
    exit 1
else
    echo "release-config: $problems warning(s); set STRICT_RELEASE_CONFIG=1 to fail the build on these."
fi
