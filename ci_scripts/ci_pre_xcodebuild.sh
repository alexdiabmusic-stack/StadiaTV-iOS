#!/bin/sh
set -e

# Inject secret API keys into Info.plist before Xcode Cloud builds.
# Add YOUTUBE_API_KEY and ODDS_API_KEY as Secret Environment Variables
# in your Xcode Cloud workflow settings.

PLIST="$CI_WORKSPACE/MyApp/Info.plist"

if [ -n "$YOUTUBE_API_KEY" ]; then
    /usr/libexec/PlistBuddy -c "Set :YouTubeAPIKey $YOUTUBE_API_KEY" "$PLIST"
    echo "Injected YouTubeAPIKey"
fi

if [ -n "$ODDS_API_KEY" ]; then
    /usr/libexec/PlistBuddy -c "Set :OddsAPIKey $ODDS_API_KEY" "$PLIST"
    echo "Injected OddsAPIKey"
fi
