#!/bin/zsh
# Packs BannerTV.app into a drag-to-Applications disk image.
# Usage: Scripts/make-dmg.sh <path/to/BannerTV.app> [output.dmg]
# The image is not notarized: that needs a Developer ID certificate (see README, "Distribution").
set -e
APP="$1"; OUT="${2:-BannerTV.dmg}"
[ -d "$APP" ] || { echo "usage: $0 BannerTV.app [out.dmg]"; exit 1; }
STAGE="$(mktemp -d)"
ditto "$APP" "$STAGE/BannerTV.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$OUT"
hdiutil create -volname "BannerTV" -srcfolder "$STAGE" -ov -format UDZO "$OUT" >/dev/null
rm -rf "$STAGE"
echo "$OUT"
