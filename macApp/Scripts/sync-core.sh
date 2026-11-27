#!/bin/zsh
# Copies the freshly built BannerCore XCFramework next to the Swift package.
set -e
SRC="${1:-$(dirname $0)/../../bannerCore/build/XCFrameworks/debug/BannerCore.xcframework}"
DST="$(dirname $0)/../Frameworks/BannerCore.xcframework"
rm -rf "$DST"; mkdir -p "$(dirname $DST)"
ditto "$SRC" "$DST"
echo "BannerCore synced from $SRC"
