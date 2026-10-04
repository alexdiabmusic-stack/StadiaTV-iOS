#!/usr/bin/env bash
# Runs every test suite in the repository and reports all failures instead of stopping at the first.
# Needs macOS with Xcode (the *CoreTests runners call xcrun; the app tests need a simulator).
#
#   scripts/test-all.sh             everything
#   scripts/test-all.sh checks      the static checks only (no Xcode needed)
#   scripts/test-all.sh packages    the *CoreTests packages and MatchLinker
#   scripts/test-all.sh app         the Xcode unit tests (MyAppUnitTests, MyAppTests)
#
# Environment: TEST_SIMULATOR (default "iPhone 17"), TEST_DESTINATION (overrides the whole
# -destination value), TEST_SCHEME (default "MyApp").
set -uo pipefail

cd "$(dirname "$0")/.."

what="${1:-all}"
failed=()

step() {
  local name="$1"; shift
  printf '\n=== %s\n' "$name"
  if "$@"; then
    printf -- '--- %s: ok\n' "$name"
  else
    printf -- '--- %s: FAILED\n' "$name"
    failed+=("$name")
  fi
}

run_checks() {
  # Fails (rather than warns) when a change adds fixed-size fonts.
  step "dynamic type ratchet" env STRICT_DYNAMIC_TYPE=1 sh scripts/check-dynamic-type.sh
}

run_packages() {
  local dir
  for dir in *CoreTests; do
    [ -f "$dir/run-tests.sh" ] || continue
    step "$dir" bash "$dir/run-tests.sh"
  done
  # StreamLinker and its golden tests are symlinked in from MyApp/Matching and MyAppTests.
  step "MatchLinker" swift test --package-path MatchLinker
}

run_app() {
  local destination="${TEST_DESTINATION:-platform=iOS Simulator,name=${TEST_SIMULATOR:-iPhone 17}}"
  step "app unit tests" xcodebuild test \
    -project "Stadia TV.xcodeproj" \
    -scheme "${TEST_SCHEME:-MyApp}" \
    -destination "$destination" \
    -only-testing:MyAppUnitTests \
    -only-testing:MyAppTests
}

case "$what" in
  all)      run_checks; run_packages; run_app ;;
  checks)   run_checks ;;
  packages) run_packages ;;
  app)      run_app ;;
  *)        echo "usage: scripts/test-all.sh [all|checks|packages|app]" >&2; exit 2 ;;
esac

printf '\n'
if [ "${#failed[@]}" -gt 0 ]; then
  printf 'Failed: %s\n' "${failed[*]}"
  exit 1
fi
echo "All suites passed."
