#!/bin/sh
# Archives the iOS app and uploads it to App Store Connect.
# Usage: scripts/release-ios.sh [build-number]   (defaults to a timestamp)
set -eu
cd "$(dirname "$0")/.."
[ -f Config/Local.xcconfig ] || { echo "Missing Config/Local.xcconfig (see Config/Local.xcconfig.example)" >&2; exit 1; }
build="${1:-$(date +%y%m%d%H%M)}"
swift test
xcodebuild -project NoteCraft.xcodeproj -scheme NoteCraft -destination 'generic/platform=iOS' \
  -configuration Release -archivePath build/NoteCraft.xcarchive \
  CURRENT_PROJECT_VERSION="$build" -allowProvisioningUpdates archive
xcodebuild -exportArchive -archivePath build/NoteCraft.xcarchive \
  -exportOptionsPlist scripts/ExportOptions.plist -allowProvisioningUpdates
