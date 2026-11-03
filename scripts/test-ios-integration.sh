#!/usr/bin/env bash
# Runs integration tests on a connected iOS device (never the simulator).
#
# Usage: scripts/test-ios-integration.sh <device name or UDID> [test files...]
# With no files, runs every *_test.dart under integration_test/.
#
# Each test is built as a profile app, installed and launched without a
# debugger: devices connected over Wi-Fi often cannot reach a test app's
# debug service, which leaves `flutter test` and `flutter drive` waiting on
# a blank screen. The tests save their results in the app's Documents folder
# (integration_test/support/results_file.dart), which this copies back.
# Afterwards the device has the last test app installed; reinstall Listenook
# with scripts/run-ios.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/environment.sh"
source "$ROOT/scripts/flutter-sdk.sh"
DEVICE="${1:?usage: test-ios-integration.sh <device name or UDID> [test files...]}"
shift
TIMEOUT_SECONDS="${LISTENOOK_IOS_TEST_TIMEOUT:-300}"
BUNDLE_ID="$(awk -F' = ' '/PRODUCT_BUNDLE_IDENTIFIER = / {gsub(/;/, "", $2); print $2; exit}' \
  "$ROOT/ios/Runner.xcodeproj/project.pbxproj")"
RESULTS="Documents/integration_test_results.json"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cd "$ROOT"
if [[ $# -eq 0 ]]; then
  set -- integration_test/*_test.dart
fi

status=0
for target in "$@"; do
  echo "==> $target"
  "$FLUTTER" build ios --profile -t "$target" >"$WORK/build.log" 2>&1 || {
    tail -n 40 "$WORK/build.log" >&2
    status=1
    continue
  }
  xcrun devicectl device install app --device "$DEVICE" \
    "$ROOT/build/ios/iphoneos/Runner.app" >/dev/null
  started="$(date +%s)"
  xcrun devicectl device process launch --terminate-existing \
    --device "$DEVICE" "$BUNDLE_ID" >/dev/null

  # Wait for a results file written after this launch.
  report=""
  while (( $(date +%s) - started < TIMEOUT_SECONDS )); do
    sleep 5
    rm -f "$WORK/results.json"
    xcrun devicectl device copy from --device "$DEVICE" \
      --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
      --source "$RESULTS" --destination "$WORK/results.json" \
      >/dev/null 2>&1 || continue
    finished="$(plutil -extract finished raw -o - "$WORK/results.json" 2>/dev/null || echo 0)"
    # Device and Mac clocks may differ by a few seconds.
    if (( finished >= started - 30 )); then
      report="$WORK/results.json"
      break
    fi
  done
  if [[ -z "$report" ]]; then
    echo "  timed out after ${TIMEOUT_SECONDS}s without results" >&2
    status=1
    continue
  fi
  /usr/bin/python3 - "$report" <<'PY' || status=1
import json, sys
report = json.load(open(sys.argv[1]))
for name, outcome in report["results"].items():
    print(("  ok    " if outcome == "success" else "  FAIL  ") + name)
    if outcome != "success":
        print("        " + outcome.replace("\n", "\n        "))
sys.exit(0 if report["passed"] else 1)
PY
done
exit "$status"
