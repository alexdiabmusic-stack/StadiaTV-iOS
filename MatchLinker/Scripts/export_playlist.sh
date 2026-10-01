#!/usr/bin/env bash
# Exports what StreamLinker needs from an Xtream playlist into OUT_DIR:
#   streams.json  cats.json  xmltv.xml
# Credentials come from the environment. Never write them into a file and never commit the output.
#
#   HOST=http://host:port XT_USER=... XT_PASS=... ./export_playlist.sh ./export
set -euo pipefail
: "${HOST:?set HOST, for example http://host:port}"
: "${XT_USER:?set XT_USER}"
: "${XT_PASS:?set XT_PASS}"
OUT="${1:-./export}"
mkdir -p "$OUT"
api() { curl -fsS --compressed "$HOST/player_api.php?username=$XT_USER&password=$XT_PASS&action=$1"; }
api get_live_streams    > "$OUT/streams.json"
api get_live_categories > "$OUT/cats.json"
curl -fsS --compressed "$HOST/xmltv.php?username=$XT_USER&password=$XT_PASS" > "$OUT/xmltv.xml"
echo "wrote $OUT/streams.json $OUT/cats.json $OUT/xmltv.xml"
echo "next: python3 export_guide_window.py $OUT/xmltv.xml $OUT/guide_window.json"
echo "      python3 export_events.py $OUT/events.json"
