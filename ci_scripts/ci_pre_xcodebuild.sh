#!/bin/sh
set -e

# Provide secret API keys to Xcode Cloud builds.
# Add YOUTUBE_API_KEY and ODDS_API_KEY as Secret Environment Variables
# in your Xcode Cloud workflow settings. They're written to the git-ignored
# Config/Secrets.xcconfig, which Config/App.xcconfig includes; Info.plist
# reads them as $(ODDS_API_KEY) and $(YOUTUBE_API_KEY).

SECRETS="$CI_PRIMARY_REPOSITORY_PATH/Config/Secrets.xcconfig"
: > "$SECRETS"

if [ -n "$YOUTUBE_API_KEY" ]; then
    echo "YOUTUBE_API_KEY = $YOUTUBE_API_KEY" >> "$SECRETS"
    echo "Provided YOUTUBE_API_KEY"
fi

if [ -n "$ODDS_API_KEY" ]; then
    echo "ODDS_API_KEY = $ODDS_API_KEY" >> "$SECRETS"
    echo "Provided ODDS_API_KEY"
fi

# Report release-readiness problems on archive builds. Warns by default; set
# STRICT_RELEASE_CONFIG=1 in the workflow to fail the build instead.
if [ "${CI_XCODEBUILD_ACTION:-}" = "archive" ]; then
    sh "$CI_PRIMARY_REPOSITORY_PATH/scripts/check-release-config.sh"
fi

# Warn when a change adds fixed-size fonts (text that ignores Dynamic Type). STRICT_DYNAMIC_TYPE=1 fails the build.
sh "$CI_PRIMARY_REPOSITORY_PATH/scripts/check-dynamic-type.sh"
