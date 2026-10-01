#!/bin/bash
set -euo pipefail
DEVICE=$(xcrun simctl list devices available --json | python3 -c 'import json,sys; print(next(d["udid"] for items in json.load(sys.stdin)["devices"].values() for d in items if d["name"].startswith("iPhone")))')
xcrun simctl boot "$DEVICE"
xcrun simctl bootstatus "$DEVICE" -b
xcrun simctl install "$DEVICE" build/Build/Products/Debug-iphonesimulator/LocalMediaPlayer.app
CONTAINER=$(xcrun simctl get_app_container "$DEVICE" com.toomiiverse.localmediaplayer data)
mkdir -p "$CONTAINER/Documents/Fixtures"
cp fixtures/check.* "$CONTAINER/Documents/Fixtures/"
xcrun simctl launch "$DEVICE" com.toomiiverse.localmediaplayer --codec-check
for i in {1..120}; do
  if [[ -f "$CONTAINER/Documents/codec-complete.txt" ]]; then break; fi
  sleep 1
done
cp "$CONTAINER/Documents/codec-results.txt" "$RUNNER_TEMP/codec-results.txt" || true
xcrun simctl io "$DEVICE" screenshot "$RUNNER_TEMP/ios-player.png"
cat "$RUNNER_TEMP/codec-results.txt" || true
test "$(cat "$CONTAINER/Documents/codec-complete.txt")" = PASS
test "$(grep -c '^PASS ' "$RUNNER_TEMP/codec-results.txt")" = 4
