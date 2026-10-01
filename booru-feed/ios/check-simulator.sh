#!/bin/bash
set -euo pipefail
if ! command -v ffmpeg >/dev/null; then brew install ffmpeg; fi
DEVICE=$(xcrun simctl list devices available --json | python3 -c 'import json,sys; print(next(d["udid"] for items in json.load(sys.stdin)["devices"].values() for d in items if d["name"].startswith("iPhone")))')
xcrun simctl boot "$DEVICE"
xcrun simctl bootstatus "$DEVICE" -b
xcrun simctl install "$DEVICE" build/Build/Products/Debug-iphonesimulator/LocalMediaPlayer.app
CONTAINER=$(xcrun simctl get_app_container "$DEVICE" com.toomiiverse.localmediaplayer data)
mkdir -p "$CONTAINER/Documents/Fixtures"
for spec in 'mp4 libx264' 'mkv mpeg4' 'avi mpeg4' 'webm libvpx'; do
  read -r extension codec <<< "$spec"
  ffmpeg -v error -f lavfi -i 'testsrc2=size=320x240:rate=24' -f lavfi -i 'sine=frequency=440' -t 12 -c:v "$codec" -c:a "$([[ "$extension" == webm ]] && echo libvorbis || echo aac)" "$CONTAINER/Documents/Fixtures/check.$extension"
done
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
