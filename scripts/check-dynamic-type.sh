#!/bin/sh
# Keeps the number of fixed-size fonts from growing. `.font(.system(size: 14))` doesn't follow the
# user's Dynamic Type setting; text styles (`Theme.Typography.*`, `.font(.subheadline)`) do.
#
# The count may only go down: when it drops, lower scripts/dynamic-type-baseline.txt to match.
# Prints a warning when the count is over the baseline; exits non-zero only when
# STRICT_DYNAMIC_TYPE=1 is set. Run by ci_scripts/ci_pre_xcodebuild.sh, or by hand:
#   scripts/check-dynamic-type.sh
set -eu

ROOT="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "$0")/.." && pwd)}"
BASELINE_FILE="$ROOT/scripts/dynamic-type-baseline.txt"
baseline=$(tr -d '[:space:]' < "$BASELINE_FILE")
count=$(grep -rE '\.font\(\.system\(size:' --include='*.swift' "$ROOT/MyApp" | wc -l | tr -d '[:space:]')

if [ "$count" -gt "$baseline" ]; then
    echo "dynamic-type: $count fixed-size fonts, up from $baseline. Use a text style (Theme.Typography.*) so the text scales; the new ones are:"
    git -C "$ROOT" diff -U0 HEAD -- MyApp 2>/dev/null | grep -E '^\+.*\.font\(\.system\(size:' || true
    [ "${STRICT_DYNAMIC_TYPE:-0}" = "1" ] && exit 1
elif [ "$count" -lt "$baseline" ]; then
    echo "dynamic-type: $count fixed-size fonts, down from $baseline. Lower scripts/dynamic-type-baseline.txt to $count."
else
    echo "dynamic-type: $count fixed-size fonts, unchanged."
fi
exit 0
