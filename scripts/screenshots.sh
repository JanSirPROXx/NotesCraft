#!/bin/sh
# Renders the App Store screenshots: iPad 13" (2064x2752) on a simulator, from sample pages that
# the debug build fills in (ScreenshotTour + --screenshot-scenes). Output: docs/screenshots/appstore/.
# Usage: scripts/screenshots.sh   (DEVICE="iPad Pro 13-inch (M5)" by default)
set -eu
cd "$(dirname "$0")/.."
device="${DEVICE:-iPad Pro 13-inch (M5)}"
out="docs/screenshots/appstore"
raw="build/screenshots-raw"
result="build/screenshots.xcresult"

udid=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
name = sys.argv[1]
for runtime, devices in json.load(sys.stdin)["devices"].items():
    for d in devices:
        if d["name"] == name:
            print(d["udid"]); sys.exit(0)
sys.exit("No simulator named " + name)' "$device")

# Start from a factory-fresh simulator: the tour creates a storage folder, and one left over from an
# earlier run would collide with its name.
xcrun simctl shutdown "$udid" 2>/dev/null || true
xcrun simctl erase "$udid"
xcrun simctl boot "$udid"
xcrun simctl bootstatus "$udid" -b >/dev/null
# A clean status bar, as on Apple's own screenshots.
xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 \
  --wifiMode active --wifiBars 3 --cellularMode notSupported

rm -rf "$result" "$raw"
mkdir -p build "$out"
TEST_RUNNER_SCREENSHOT_TOUR=1 xcodebuild -project NoteCraft.xcodeproj -scheme NoteCraft-iPad \
  -destination "platform=iOS Simulator,id=$udid" -resultBundlePath "$result" \
  test -only-testing:NoteCraftUITests/ScreenshotTour
xcrun xcresulttool export attachments --path "$result" --output-path "$raw"

python3 - "$raw" "$out" <<'PY'
import json, os, shutil, sys
raw, out = sys.argv[1:3]
manifest = json.load(open(os.path.join(raw, "manifest.json")))
for test in manifest:
    for attachment in test.get("attachments", []):
        name = attachment["suggestedHumanReadableName"].split("_")[0]
        src = os.path.join(raw, attachment["exportedFileName"])
        shutil.copy(src, os.path.join(out, name + ".png"))
        print("wrote", os.path.join(out, name + ".png"))
PY
xcrun simctl status_bar "$udid" clear
