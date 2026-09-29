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
